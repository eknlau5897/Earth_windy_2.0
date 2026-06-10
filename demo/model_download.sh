#!/usr/bin/env bash
set -euo pipefail # Fail-fast shell architecture

OUTPUT_DIR="./data"
SCRATCH_DIR="./.tmp_scratch"
CHECK_INTERVAL=10800 

# Repository structural targets
BRANCH="main"
githubUser="eknlau5897"
githubRepo="Earth_windy_2.0"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$SCRATCH_DIR"

# Force Herbie to use your clean scratch directory as its cache path
export HERBIE_DATA="$SCRATCH_DIR"

FORECAST_HOURS=()
for ((h=0; h<=120; h+=6)); do FORECAST_HOURS+=($(printf "%03d" "$h")); done
for ((h=132; h<=240; h+=12)); do FORECAST_HOURS+=($(printf "%03d" "$h")); done

echo "=================================================================="
echo "   HERBIE TRIPLE-MODEL DAEMON ENGINE (GFS | IFS | AIFS) v7"
echo "=================================================================="

while true; do
    echo "--- 任務開始: $(date) ---"
    
    CURRENT_HOUR=$(date -u +"%H")
    CURRENT_DATE=$(date -u +"%Y-%m-%d")
    FILE_DATE=$(date -u +"%Y%m%d")

    # ==============================================================================
    # 1. MODEL RUN DETERMINATION PLUMBING (UNIVERSAL MAC/LINUX COMPATIBLE)
    # ==============================================================================
    if date -u -d "yesterday" +"%Y-%m-%d" >/dev/null 2>&1; then
        # GNU Linux Environment
        YESTERDAY=$(date -u -d "yesterday" +"%Y-%m-%d")
    else
        # macOS BSD Environment
        YESTERDAY=$(date -u -v-1d +"%Y-%m-%d")
    fi

    if [ "$CURRENT_HOUR" -ge 6 ] && [ "$CURRENT_HOUR" -lt 12 ]; then
        GFS_CYCLE="00"; GFS_DATE="${CURRENT_DATE} 00:00"
    elif [ "$CURRENT_HOUR" -ge 12 ] && [ "$CURRENT_HOUR" -lt 18 ]; then
        GFS_CYCLE="06"; GFS_DATE="${CURRENT_DATE} 06:00"
    elif [ "$CURRENT_HOUR" -ge 18 ] && [ "$CURRENT_HOUR" -lt 23 ]; then
        GFS_CYCLE="12"; GFS_DATE="${CURRENT_DATE} 12:00"
    else
        GFS_CYCLE="18"
        if [ "$CURRENT_HOUR" -lt 6 ]; then
            GFS_DATE="${YESTERDAY} 18:00"
        else
            GFS_DATE="${CURRENT_DATE} 18:00"
        fi
    fi

    if [ "$CURRENT_HOUR" -ge 9 ] && [ "$CURRENT_HOUR" -lt 21 ]; then
        IFS_CYCLE="00"; IFS_DATE="${CURRENT_DATE} 00:00"
    else
        IFS_CYCLE="12"
        if [ "$CURRENT_HOUR" -lt 9 ]; then
            IFS_DATE="${YESTERDAY} 12:00"
        else
            IFS_DATE="${CURRENT_DATE} 12:00"
        fi
    fi

    if [ "$CURRENT_HOUR" -ge 7 ] && [ "$CURRENT_HOUR" -lt 19 ]; then
        AIFS_CYCLE="00"; AIFS_DATE="${CURRENT_DATE} 00:00"
    else
        AIFS_CYCLE="12"
        if [ "$CURRENT_HOUR" -lt 7 ]; then
            AIFS_DATE="${YESTERDAY} 12:00"
        else
            AIFS_DATE="${CURRENT_DATE} 12:00"
        fi
    fi

    export GFS_DATE; export IFS_DATE; export AIFS_DATE; export SCRATCH_DIR

    CYCLE_ID="${FILE_DATE}_gfs${GFS_CYCLE}_ifs${IFS_CYCLE}_aifs${AIFS_CYCLE}"
    success_lockfile="$OUTPUT_DIR/.success_${CYCLE_ID}"

    if [ -f "$success_lockfile" ]; then
        echo "[Daemon Track] Cycle configuration ${CYCLE_ID} processed. Idling..."
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    DATA_ERROR_OCCURRED=0

    # ==============================================================================
    # 2. RUN PY311 PARSER LOOP (Switched to safe 'EOF' encapsulation)
    # ==============================================================================
    for fhr in "${FORECAST_HOURS[@]}"; do
        CLEAN_HOUR=$((10#$fhr))
        export CLEAN_HOUR; export fhr

        # Notice the single quotes around 'EOF'. This prevents Bash from interfering with Python code
        python3.11 - <<'EOF'
import os, sys, json, gzip
import numpy as np
from herbie import Herbie

gfs_date_env = os.environ.get("GFS_DATE")
ifs_date_env = os.environ.get("IFS_DATE")
aifs_date_env = os.environ.get("AIFS_DATE")
clean_hour_env = int(os.environ.get("CLEAN_HOUR", 0))
fhr_env = os.environ.get("fhr")
scratch_dir = os.environ.get("SCRATCH_DIR", "./.tmp_scratch")

def build_json(param, level, ds, u_var, v_var=None, is_pressure_level=False):
    if ds is None: return None
    try:
        lon_key = 'longitude' if 'longitude' in ds.coords else 'lon'
        lat_key = 'latitude' if 'latitude' in ds.coords else 'lat'
        
        if u_var not in ds.data_vars:
            alternatives = [
                u_var.lower(), u_var.upper(), 
                '10u' if u_var in ['u10', 'u'] else '', 
                'u10' if u_var in ['10u', 'u'] else '',
                'u', 'ugrd', 'UGRD'
            ]
            for alt in alternatives:
                if alt and alt in ds.data_vars: u_var = alt; break
                
        if v_var and v_var not in ds.data_vars:
            alternatives = [
                v_var.lower(), v_var.upper(), 
                '10v' if v_var in ['v10', 'v'] else '', 
                'v10' if v_var in ['10v', 'v'] else '',
                'v', 'vgrd', 'VGRD'
            ]
            for alt in alternatives:
                if alt and alt in ds.data_vars: v_var = alt; break

        if v_var:
            if u_var not in ds.data_vars or v_var not in ds.data_vars:
                raise KeyError(f"Could not find wind variables in dataset. Found: {list(ds.data_vars)}")
                
            u_vals = ds[u_var].values
            v_vals = ds[v_var].values
            
            if is_pressure_level:
                p_coord = next((c for c in ['isobaricInhPa', 'plev', 'level', 'isobaricInhPa_0'] if c in ds.coords), None)
                if p_coord:
                    p_array = list(np.atleast_1d(ds[p_coord].values))
                    target = level * 100 if p_coord == 'plev' else level
                    
                    if len(u_vals.shape) > 2 and target in p_array:
                        idx = p_array.index(target)
                        u_vals = u_vals[idx]
                        v_vals = v_vals[idx]
                        
            return [
                {"header": {"parameterName": "U-component of wind", "surface1Value": level, "nx": len(ds[lon_key]), "ny": len(ds[lat_key]), "lo1": float(ds[lon_key].min()), "la1": float(ds[lat_key].max()), "lo2": float(ds[lon_key].max()), "la2": float(ds[lat_key].min()), "dx": 0.25, "dy": 0.25}, "data": np.where(np.isnan(u_vals), 0, u_vals).flatten().tolist()},
                {"header": {"parameterName": "V-component of wind", "surface1Value": level, "nx": len(ds[lon_key]), "ny": len(ds[lat_key]), "lo1": float(ds[lon_key].min()), "la1": float(ds[lat_key].max()), "lo2": float(ds[lon_key].max()), "la2": float(ds[lat_key].min()), "dx": 0.25, "dy": 0.25}, "data": np.where(np.isnan(v_vals), 0, v_vals).flatten().tolist()}
            ]
        else:
            if u_var not in ds.data_vars:
                raise KeyError(f"Could not find variable {u_var} in dataset. Found: {list(ds.data_vars)}")
            vals = ds[u_var].values
            return {"header": {"parameterName": param, "surface1Value": level, "nx": len(ds[lon_key]), "ny": len(ds[lat_key]), "lo1": float(ds[lon_key].min()), "la1": float(ds[lat_key].max()), "lo2": float(ds[lon_key].max()), "la2": float(ds[lat_key].min()), "dx": 0.25, "dy": 0.25}, "data": np.where(np.isnan(vals), 0, vals).flatten().tolist()}
    except Exception as e:
        print(f"Extraction error processing f{fhr_env}: {e}")
        return None

def save_gzip(data, filename):
    if data is None: return
    with gzip.open(os.path.join(scratch_dir, filename), "wt", encoding="utf-8") as f: 
        json.dump(data, f)

def safe_xarray_fetch(herbie_obj, search_string):
    try: return herbie_obj.xarray(search_string)
    except:
        try: herbie_obj.download(); return herbie_obj.xarray(search_string)
        except: return None

# --- MODEL A: NOAA GFS ARRAYS ---
try:
    Hg = Herbie(gfs_date_env, model="gfs", product="pgrb2.0p25", fxx=clean_hour_env, verbose=False, overwrite=True)
    save_gzip(build_json("Pressure reduced to MSL", 0, safe_xarray_fetch(Hg, ":PRMSL:mean sea level:"), "prmsl"), f"gfs_mslp_f{fhr_env}.json.gz")
    if clean_hour_env > 0: 
        save_gzip(build_json("Total Precipitation", 0, safe_xarray_fetch(Hg, ":APCP:surface:"), "tp"), f"gfs_rain_f{fhr_env}.json.gz")
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(Hg, ":(U|V)GRD:10 m above ground:"), "u10", "v10"), f"gfs_10m_f{fhr_env}.json.gz")
    
    for p in [850, 700, 500, 200]:
        save_gzip(build_json("Wind", p, safe_xarray_fetch(Hg, f":(U|V)GRD:{p} mb:"), "ugrd", "vgrd", True), f"gfs_{p}_f{fhr_env}.json.gz")
    del Hg
except Exception as e:
    print(f"⚠️ GFS Fetch failed for hour {fhr_env}: {e}")

# --- MODEL B: ECMWF IFS PHYSICAL ARRAYS ---
try:
    He = Herbie(ifs_date_env, model="ifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False, overwrite=True)
    save_gzip(build_json("Pressure reduced to MSL", 0, safe_xarray_fetch(He, ":msl:"), "msl"), f"ecmwf_mslp_f{fhr_env}.json.gz")
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(He, ":10(u|v):"), "10u", "10v"), f"ecmwf_10m_f{fhr_env}.json.gz")
    
    for p in [850, 700, 500, 200]:
        save_gzip(build_json("Wind", p, safe_xarray_fetch(He, f":(u|v):{p}:"), "u", "v", True), f"ecmwf_{p}_f{fhr_env}.json.gz")
    del He
except Exception as e:
    print(f"⚠️ ECMWF IFS Fetch failed for hour {fhr_env}: {e}")

# --- MODEL C: ECMWF AIFS NEURAL NET ARRAYS ---
try:
    Ha = Herbie(aifs_date_env, model="aifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False, overwrite=True)
    save_gzip(build_json("Pressure reduced to MSL", 0, safe_xarray_fetch(Ha, ":msl:"), "msl"), f"aifs_mslp_f{fhr_env}.json.gz")
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(Ha, ":10(u|v):"), "10u", "10v"), f"aifs_10m_f{fhr_env}.json.gz")
    
    for p in [850, 700, 500, 200]:
        save_gzip(build_json("Wind", p, safe_xarray_fetch(Ha, f":(u|v):{p}:"), "u", "v", True), f"aifs_{p}_f{fhr_env}.json.gz")
    del Ha
except Exception as e:
    print(f"⚠️ ECMWF AIFS Fetch failed for hour {fhr_env}: {e}")
EOF

        if [ $? -ne 0 ]; then 
            DATA_ERROR_OCCURRED=1
        else
            find "$SCRATCH_DIR" -type f -name "*.json.gz" -exec mv {} "$OUTPUT_DIR/" \;
        fi
    done

    # ==============================================================================
    # 3. HISTORY COLLAPSE PIPELINE (CLEAN SINGLE-COMMIT FORCE PUSH)
    # ==============================================================================
    file_count=$(find "$OUTPUT_DIR" -type f -name "*.json.gz" | wc -l)

    if [ "$file_count" -gt 0 ] && [ "$DATA_ERROR_OCCURRED" -eq 0 ]; then
        touch "$success_lockfile"
        
        if [ ! -d ".git" ]; then
            git init
            git checkout -b "$BRANCH"
        fi
    fi

    find "$SCRATCH_DIR" -type f ! -name "*.idx" -delete 2>/dev/null
    echo "[Cycle Complete] Sleeping for $((CHECK_INTERVAL / 60)) minutes..."
    sleep "$CHECK_INTERVAL"
done