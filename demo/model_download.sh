#!/usr/bin/env bash
set -euo pipefail # Fail-fast shell architecture

OUTPUT_DIR="./data"
SCRATCH_DIR="./.tmp_scratch"
CWA_INPUT_DIR="/Users/eknlau/Desktop/CWA/accu_rain/"  # Verified local Desktop path
CHECK_INTERVAL=21600 

# Repository structural targets
BRANCH="main"
githubUser="eknlau5897"
githubRepo="Earth_windy_2.0"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$SCRATCH_DIR"
mkdir -p "$CWA_INPUT_DIR"

export HERBIE_DATA="$SCRATCH_DIR"

FORECAST_HOURS=()
for ((h=0; h<=120; h+=6)); do FORECAST_HOURS+=($(printf "%03d" "$h")); done
for ((h=132; h<=240; h+=12)); do FORECAST_HOURS+=($(printf "%03d" "$h")); done

echo "=================================================================="
echo "   HERBIE + CWA XARRAY NATIVE DAEMON ENGINE v11"
echo "=================================================================="

while true; do
    echo "--- 任務開始: $(date) ---"
    
    CURRENT_HOUR=$(date -u +"%H")
    CURRENT_DATE=$(date -u +"%Y-%m-%d")
    FILE_DATE=$(date -u +"%Y%m%d")

    if date -u -d "yesterday" +"%Y-%m-%d" >/dev/null 2>&1; then
        YESTERDAY=$(date -u -d "yesterday" +"%Y-%m-%d")
    else
        YESTERDAY=$(date -u -v-1d +"%Y-%m-%d")
    fi

    if [ "$CURRENT_HOUR" -ge 6 ] && [ "$CURRENT_HOUR" -lt 18 ]; then
        GFS_CYCLE="00"; GFS_DATE="${CURRENT_DATE} 00:00"
    elif [ "$CURRENT_HOUR" -ge 18 ] && [ "$CURRENT_HOUR" -lt 24 ]; then
        GFS_CYCLE="12"; GFS_DATE="${CURRENT_DATE} 12:00"
    else
        GFS_CYCLE="18"
        if [ "$CURRENT_HOUR" -lt 6 ]; then
            GFS_DATE="${YESTERDAY} 12:00"
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

    export GFS_DATE; export IFS_DATE; export AIFS_DATE; export SCRATCH_DIR; export CWA_INPUT_DIR

    CYCLE_ID="${FILE_DATE}_gfs${GFS_CYCLE}_ifs${IFS_CYCLE}_aifs${AIFS_CYCLE}"
    success_lockfile="$OUTPUT_DIR/.success_${CYCLE_ID}"

    if [ -f "$success_lockfile" ]; then
        echo "[Daemon Track] Cycle configuration ${CYCLE_ID} processed. Idling..."
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    DATA_ERROR_OCCURRED=0

    for fhr in "${FORECAST_HOURS[@]}"; do
        CLEAN_HOUR=$((10#$fhr))
        export CLEAN_HOUR; export fhr

        python3.11 - <<'EOF'
import os, sys, json, gzip
import numpy as np
import xarray as xr
from herbie import Herbie

gfs_date_env = os.environ.get("GFS_DATE")
ifs_date_env = os.environ.get("IFS_DATE")
aifs_date_env = os.environ.get("AIFS_DATE")
clean_hour_env = int(os.environ.get("CLEAN_HOUR", 0))
fhr_env = os.environ.get("fhr")
scratch_dir = os.environ.get("SCRATCH_DIR", "./.tmp_scratch")
cwa_input_dir = os.environ.get("CWA_INPUT_DIR", "./cwa_raw_folder")

def build_json(param, level, ds, u_var, v_var=None, is_pressure_level=False):
    if ds is None: return None
    try:
        lon_key = 'longitude' if 'longitude' in ds.coords else 'lon'
        lat_key = 'latitude' if 'latitude' in ds.coords else 'lat'
        
        lons = ds[lon_key].values
        lats = ds[lat_key].values
        
        nx = lons.shape[1] if len(lons.shape) > 1 else len(lons)
        ny = lats.shape[0] if len(lats.shape) > 1 else len(lats)
        
        u_vals = ds[u_var].values
        v_vals = ds[v_var].values if v_var else None
        
        if is_pressure_level and v_var:
            p_coord = next((c for c in ['isobaricInhPa', 'plev', 'level'] if c in ds.coords), None)
            if p_coord:
                p_array = list(np.atleast_1d(ds[p_coord].values))
                target = level * 100 if p_coord == 'plev' else level
                if len(u_vals.shape) > 2 and target in p_array:
                    idx = p_array.index(target)
                    u_vals = u_vals[idx]
                    v_vals = v_vals[idx]

        if len(lats.shape) == 1 and lats[0] < lats[-1]:
            u_vals = np.flipud(u_vals)
            if v_var: v_vals = np.flipud(v_vals)
        elif len(lats.shape) > 1 and lats[0,0] < lats[-1,0]:
            u_vals = np.flipud(u_vals)
            if v_var: v_vals = np.flipud(v_vals)

        return [
            {"header": {"parameterName": "U-component of wind", "surface1Value": level, "nx": nx, "ny": ny, "lo1": float(lons.min()), "la1": float(lats.max()), "lo2": float(lons.max()), "la2": float(lats.min()), "dx": 0.25, "dy": 0.25}, "data": np.where(np.isnan(u_vals), 0, u_vals).flatten().tolist()},
            {"header": {"parameterName": "V-component of wind", "surface1Value": level, "nx": nx, "ny": ny, "lo1": float(lons.min()), "la1": float(lats.max()), "lo2": float(lons.max()), "la2": float(lats.min()), "dx": 0.25, "dy": 0.25}, "data": np.where(np.isnan(v_vals), 0, v_vals).flatten().tolist()}
        ]
    except Exception as e:
        print(f"Extraction error processing fields: {e}")
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

# --- PROCESS GLOBAL WEATHER MODELS (GFS, IFS, AIFS) ---
try:
    Hg = Herbie(gfs_date_env, model="gfs", product="pgrb2.0p25", fxx=clean_hour_env, verbose=False)
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(Hg, ":(U|V)GRD:10 m above ground:"), "u10", "v10"), f"gfs_10m_f{fhr_env}.json.gz")
    
    # Safe adaptive fallback for GFS upper-air keys ('u' vs 'ugrd')
    gfs_plev_ds = safe_xarray_fetch(Hg, ":(U|V)GRD:(850|700|500|200) mb:")
    if gfs_plev_ds is not None:
        gfs_u = "u" if "u" in gfs_plev_ds.data_vars else "ugrd"
        gfs_v = "v" if "v" in gfs_plev_ds.data_vars else "vgrd"
        for p in [850, 700, 500, 200]:
            save_gzip(build_json("Wind", p, gfs_plev_ds, gfs_u, gfs_v, True), f"gfs_{p}_f{fhr_env}.json.gz")
except Exception as e: print(f"GFS Skip: {e}")

try:
    He = Herbie(ifs_date_env, model="ifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False)
    # Fixed keys to align with the modern ECMWF coordinate structure ('u10' / 'v10')
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(He, ":10(u|v):"), "u10", "v10"), f"ecmwf_10m_f{fhr_env}.json.gz")
    for p in [850, 700, 500, 200]:
        save_gzip(build_json("Wind", p, safe_xarray_fetch(He, f":(u|v):{p}:"), "u", "v", True), f"ecmwf_{p}_f{fhr_env}.json.gz")
except Exception as e: print(f"IFS Skip: {e}")

try:
    Ha = Herbie(aifs_date_env, model="aifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False)
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(Ha, ":10(u|v):"), "u10", "v10"), f"aifs_10m_f{fhr_env}.json.gz")
    for p in [850, 700, 500, 200]:
        save_gzip(build_json("Wind", p, safe_xarray_fetch(Ha, f":(u|v):{p}:"), "u", "v", True), f"aifs_{p}_f{fhr_env}.json.gz")
except Exception as e: print(f"AIFS Skip: {e}")


# ==========================================================
# --- TAIWAN CWA WRF NATIVE ENGINE (EXACT INDEXING) ---
# ==========================================================
if fhr_env == "000":
    print(f"ℹ️ Skipping step f000 for CWA WRF (Native operational products begin at f006).")
elif clean_hour_env <= 84:
    raw_grib_name = f"{fhr_env}.grb2"
    grib_target_path = os.path.join(cwa_input_dir, raw_grib_name)

    if os.path.exists(grib_target_path):
        try:
            import cfgrib
            datasets = cfgrib.open_datasets(grib_target_path)
            
            # --- 1. Process 10m Surface Layer (datasets[0]) ---
            ds_surface = datasets[0]
            cwa_10m_json = build_json("Wind", 10, ds_surface, "u10", "v10")
            save_gzip(cwa_10m_json, f"cwawrf_10m_f{fhr_env}.json.gz")
            
            # --- 2. Process Pressure Levels (datasets[2]) ---
            ds_pressure = datasets[2]
            
            level_mappings = {
                850: 2,  # maps to datasets[2].u[2]
                700: 3,  # maps to datasets[2].u[3]
                500: 4,  # maps to datasets[2].u[4]
                200: 8   # maps to datasets[2].u[8]
            }
            
            for p_level, idx in level_mappings.items():
                try:
                    ds_slice = ds_pressure.isel(isobaricInhPa=idx)
                    cwa_p_json = build_json("Wind", p_level, ds_slice, "u", "v", is_pressure_level=False)
                    save_gzip(cwa_p_json, f"cwawrf_{p_level}_f{fhr_env}.json.gz")
                except Exception as slice_err:
                    print(f"⚠️ Failed slicing pressure index [{idx}] for {p_level}hPa: {slice_err}")
            
            for ds in datasets:
                ds.close()
                
            print(f"Successfully compiled indexed CWA WRF structures for step f{fhr_env}")
        except Exception as e:
            print(f"⚠️ CWA WRF engine parsing breakdown at step f{fhr_env}: {e}")
    else:
        print(f"⚠️ Warning: Expected CWA WRF file [{raw_grib_name}] is missing from source path.")
EOF

        if [ $? -ne 0 ]; then 
            DATA_ERROR_OCCURRED=1
        else
            find "$SCRATCH_DIR" -type f -name "*.json.gz" -exec mv {} "$OUTPUT_DIR/" \;
        fi
    done

    # Cleanup backend indexes (.idx) left behind by the cfgrib engine
    find "$CWA_INPUT_DIR" -type f -name "*.idx" -delete 2>/dev/null
    find "$SCRATCH_DIR" -type f -delete 2>/dev/null
    
    echo "[Cycle Complete] Sleeping..."
    sleep "$CHECK_INTERVAL"
done