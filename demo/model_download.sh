#!/bin/bash

OUTPUT_DIR="./data"
SCRATCH_DIR="./.tmp_scratch"
CHECK_INTERVAL=3600 

# Define repository variables for the dynamic re-initialization matrix
BRANCH="main"
githubUser="eknlau5897"
githubRepo="Earth_windy_2.0"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$SCRATCH_DIR"

# Force Herbie to use your clean scratch directory as its cache path
export HERBIE_DATA="$SCRATCH_DIR"

FORECAST_HOURS=()
for ((h=0; h<=120; h+=6)); do FORECAST_HOURS+=($(printf "%03d" $h)); done
for ((h=132; h<=240; h+=12)); do FORECAST_HOURS+=($(printf "%03d" $h)); done

echo "=================================================================="
echo "   HERBIE DECOUPLED TRIPLE-MODEL DAEMON ENGINE (macOS BUILD)     "
echo "=================================================================="

while true; do
    CURRENT_HOUR=$(date -u +"%H")
    CURRENT_DATE=$(date -u +"%Y-%m-%d")
    FILE_DATE=$(date -u +"%Y%m%d")

    # ==============================================================================
    # 1. MODEL RUN DETERMINATION PLUMBING
    # ==============================================================================
    if [ "$CURRENT_HOUR" -ge 6 ] && [ "$CURRENT_HOUR" -lt 12 ]; then
        GFS_CYCLE="00"; GFS_DATE="${CURRENT_DATE} 00:00"
    elif [ "$CURRENT_HOUR" -ge 12 ] && [ "$CURRENT_HOUR" -lt 18 ]; then
        GFS_CYCLE="06"; GFS_DATE="${CURRENT_DATE} 06:00"
    elif [ "$CURRENT_HOUR" -ge 18 ] && [ "$CURRENT_HOUR" -lt 23 ]; then
        GFS_CYCLE="12"; GFS_DATE="${CURRENT_DATE} 12:00"
    else
        GFS_CYCLE="18"
        if [ "$CURRENT_HOUR" -lt 6 ]; then
            YESTERDAY=$(date -u -v-1d +"%Y-%m-%d")
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
            YESTERDAY=$(date -u -v-1d +"%Y-%m-%d")
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
            YESTERDAY=$(date -u -v-1d +"%Y-%m-%d")
            AIFS_DATE="${YESTERDAY} 12:00"
        else
            AIFS_DATE="${CURRENT_DATE} 12:00"
        fi
    fi

    export GFS_DATE
    export IFS_DATE
    export AIFS_DATE

    CYCLE_ID="${FILE_DATE}_gfs${GFS_CYCLE}_ifs${IFS_CYCLE}_aifs${AIFS_CYCLE}"
    success_lockfile="$OUTPUT_DIR/.success_${CYCLE_ID}"

    if [ -f "$success_lockfile" ]; then
        echo "[Daemon Track] Cycle configuration ${CYCLE_ID} processed. Idling..."
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    DATA_ERROR_OCCURRED=0

    for fhr in "${FORECAST_HOURS[@]}"; do
        CLEAN_HOUR=$(echo "$fhr" | sed 's/^0*//')
        [ -z "$CLEAN_HOUR" ] && CLEAN_HOUR="0"

        export CLEAN_HOUR
        export fhr

        # --- PY311 INTERFACE MATRIX ---
        python3.11 - <<EOF
import os, sys, json, gzip
import numpy as np
from herbie import Herbie

gfs_date_env = os.environ.get("GFS_DATE")
ifs_date_env = os.environ.get("IFS_DATE")
aifs_date_env = os.environ.get("AIFS_DATE")
clean_hour_env = int(os.environ.get("CLEAN_HOUR", 0))
fhr_env = os.environ.get("fhr")

def build_json(param, level, ds, u_var, v_var=None, is_pressure_level=False):
    if ds is None: 
        return None
    try:
        lon_key = 'longitude' if 'longitude' in ds.coords else 'lon'
        lat_key = 'latitude' if 'latitude' in ds.coords else 'lat'
        
        if u_var not in ds.data_vars:
            alternatives = [
                u_var.lower(), u_var.upper(), 
                '10u' if u_var in ['u10', 'u'] else '', 
                'u10' if u_var in ['10u', 'u'] else '',
                '10v' if v_var in ['v10', 'v'] else '',
                'v10' if v_var in ['10v', 'v'] else ''
            ]
            for alt in alternatives:
                if alt and alt in ds.data_vars:
                    if v_var:
                        alt_v = alt.replace('u','v').replace('U','V')
                        if alt_v in ds.data_vars:
                            u_var = alt; v_var = alt_v; break
                    else:
                        u_var = alt; break

        if v_var:
            u_vals = ds[u_var].values
            v_vals = ds[v_var].values
            if is_pressure_level:
                p_coord = None
                for c in ['isobaricInhPa', 'plev', 'level']:
                    if c in ds.coords: p_coord = c; break
                if p_coord:
                    p_array = list(ds[p_coord].values)
                    target = level * 100 if p_coord == 'plev' else level
                    if target in p_array:
                        idx = p_array.index(target)
                        u_vals = u_vals[idx]; v_vals = v_vals[idx]
            
            u_clean = np.where(np.isnan(u_vals), 0, u_vals).flatten().tolist()
            v_clean = np.where(np.isnan(v_vals), 0, v_vals).flatten().tolist()
            return [
                {"header": {"parameterName": "U-component of wind", "surface1Value": level, "nx": len(ds[lon_key]), "ny": len(ds[lat_key]), "lo1": float(ds[lon_key].min()), "la1": float(ds[lat_key].max()), "lo2": float(ds[lon_key].max()), "la2": float(ds[lat_key].min()), "dx": 0.25, "dy": 0.25}, "data": u_clean},
                {"header": {"parameterName": "V-component of wind", "surface1Value": level, "nx": len(ds[lon_key]), "ny": len(ds[lat_key]), "lo1": float(ds[lon_key].min()), "la1": float(ds[lat_key].max()), "lo2": float(ds[lon_key].max()), "la2": float(ds[lat_key].min()), "dx": 0.25, "dy": 0.25}, "data": v_clean}
            ]
        else:
            vals = ds[u_var].values
            clean_vals = np.where(np.isnan(vals), 0, vals).flatten().tolist()
            return {"header": {"parameterName": param, "surface1Value": level, "nx": len(ds[lon_key]), "ny": len(ds[lat_key]), "lo1": float(ds[lon_key].min()), "la1": float(ds[lat_key].max()), "lo2": float(ds[lon_key].max()), "la2": float(ds[lat_key].min()), "dx": 0.25, "dy": 0.25}, "data": clean_vals}
    except Exception as e:
        print(f"Extraction error on {param}: {e}", file=sys.stderr)
        return None

def save_gzip(data, filename):
    if data is None: return
    scratch_path = os.path.join("${SCRATCH_DIR}", filename)
    with gzip.open(scratch_path, "wt", encoding="utf-8") as f:
        json.dump(data, f)

def safe_xarray_fetch(herbie_obj, search_string):
    try:
        return herbie_obj.xarray(search_string)
    except Exception as e:
        err_msg = str(e)
        if "index" in err_msg or "None" in err_msg or "index_as_dataframe" in err_msg:
            print(f"Index mapping error. Triggering full file stream fallback...")
            try: del herbie_obj.index_as_dataframe
            except: pass
            try:
                herbie_obj.download()
                return herbie_obj.xarray(search_string)
            except Exception as inner_err:
                print(f"Fallback failure: {inner_err}")
                return None
        else:
            print(f"Fetch failed: {e}")
            return None

# --- GFS ---
try:
    Hg = Herbie(gfs_date_env, model="gfs", product="pgrb2.0p25", fxx=clean_hour_env, verbose=False, overwrite=True)
    try: save_gzip(build_json("Pressure reduced to MSL", 0, safe_xarray_fetch(Hg, ":PRMSL:mean sea level:"), "prmsl"), f"gfs_mslp_f{fhr_env}.json.gz")
    except Exception as e: print(f"GFS MSLP Error: {e}")
    if clean_hour_env > 0:
        try: save_gzip(build_json("Total Precipitation", 0, safe_xarray_fetch(Hg, ":APCP:surface:"), "tp"), f"gfs_rain_f{fhr_env}.json.gz")
        except Exception as e: print(f"GFS Rain Error: {e}")
    try: save_gzip(build_json("Wind", 10, safe_xarray_fetch(Hg, ":(U|V)GRD:10 m above ground:"), "u10", "v10"), f"gfs_10m_f{fhr_env}.json.gz")
    except Exception as e: print(f"GFS 10m Wind Error: {e}")
    try:
        ds_g_pres = safe_xarray_fetch(Hg, ":(U|V)GRD:(850|700|500|200) mb:")
        if ds_g_pres is not None:
            for lvl in [850, 700, 500, 200]:
                save_gzip(build_json("Wind", lvl, ds_g_pres, "u", "v", is_pressure_level=True), f"gfs_{lvl}_f{fhr_env}.json.gz")
    except Exception as e: print(f"GFS Pressure Levels Error: {e}")
    try: Hg.remove()
    except: pass
except Exception as e:
    print(f"⚠️ GFS Master Pipeline Blocked: {e}", file=sys.stderr)

# --- IFS ---
try:
    He = Herbie(ifs_date_env, model="ifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False, overwrite=True)
    try: save_gzip(build_json("Pressure reduced to MSL", 0, safe_xarray_fetch(He, ":msl:"), "msl"), f"ecmwf_mslp_f{fhr_env}.json.gz")
    except Exception as e: print(f"IFS MSLP Error: {e}")
    try: save_gzip(build_json("Wind", 10, safe_xarray_fetch(He, ":(10u|10v):"), "10u", "10v"), f"ecmwf_10m_f{fhr_env}.json.gz")
    except Exception as e: print(f"IFS 10m Wind Error: {e}")
    try:
        ds_e_pres = safe_xarray_fetch(He, ":(u|v):(850|700|500|200):")
        if ds_e_pres is not None:
            for lvl in [850, 700, 500, 200]:
                save_gzip(build_json("Wind", lvl, ds_e_pres, "u", "v", is_pressure_level=True), f"ecmwf_{lvl}_f{fhr_env}.json.gz")
    except Exception as e: print(f"IFS Pressure Levels Error: {e}")
    try: He.remove()
    except: pass
except Exception as e:
    print(f"⚠️ IFS Master Pipeline Blocked: {e}", file=sys.stderr)

# --- AIFS ---
try:
    Ha = Herbie(aifs_date_env, model="aifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False, overwrite=True)
    try:
        ds_a_sfc = safe_xarray_fetch(Ha, ":(10u|10v|msl):")
        if ds_a_sfc is not None:
            save_gzip(build_json("Pressure reduced to MSL", 0, ds_a_sfc, "msl"), f"aifs_mslp_f{fhr_env}.json.gz")
            save_gzip(build_json("Wind", 10, ds_a_sfc, "10u", "10v"), f"aifs_10m_f{fhr_env}.json.gz")
    except Exception as e: print(f"AIFS Surface Error: {e}")
    try:
        ds_a_pres = safe_xarray_fetch(Ha, ":(u|v):(850|700|500|200):")
        if ds_a_pres is not None:
            for lvl in [850, 700, 500, 200]:
                save_gzip(build_json("Wind", lvl, ds_a_pres, "u", "v", is_pressure_level=True), f"aifs_{lvl}_f{fhr_env}.json.gz")
    except Exception as e: print(f"AIFS Pressure Levels Error: {e}")
    try: Ha.remove()
    except: pass
except Exception as e:
    print(f"⚠️ AIFS Master Pipeline Blocked: {e}", file=sys.stderr)

EOF
        if [ $? -ne 0 ]; then 
            DATA_ERROR_OCCURRED=1
        else
            find "$SCRATCH_DIR" -type f -name "*.json.gz" -exec mv {} "$OUTPUT_DIR/" \;
            echo "[Sync Complete] Step +${fhr}h processed safely."
        fi
    done

    # ==============================================================================
    # 🏎️ DESTRUCTIVE CLEANUP ENGINE (FIXED VARIABLES & STAGING PATHWAYS)
    # ==============================================================================
    file_count=$(find "$OUTPUT_DIR" -type f -name "*.json.gz" | wc -l)

    if [ "$file_count" -gt 0 ] && [ $DATA_ERROR_OCCURRED -eq 0 ]; then
        touch "$success_lockfile"
        echo "[Engine Purge] Cleaning local cache data and reconfiguring Git LFS..."
        
        # Capture critical baseline scripts before wiping history
        SCRIPT_NAME=$(basename "$0")

        # 1. Blow away tracking references completely
        rm -rf .git
        git gc --prune=now --aggressive 2>/dev/null
        
        # 2. Re-initialize baseline plumbing links
        git init
        git checkout -b "$BRANCH"
        git remote add origin "https://github.com/${githubUser}/${githubRepo}.git"

        # 4. Stage your foundational project code alongside datasets
        git add "$SCRIPT_NAME"
        git add ./data/*.json.gz
        
        if [ -f "./index.html" ]; then git add index.html; fi
        if [ -f "./GHMWS.png" ]; then git add GHMWS.png; fi
        if [ -d "./demo" ]; then git add ./demo/* 2>/dev/null; fi

        # 5. Commit everything into 1 single history baseline frame
        git commit -m "complete: cycle ${CYCLE_ID} - ${file_count} files synced (LFS Cleared)"
        
        # 6. Force push upstream safely utilizing defined parameters
        echo "[Engine Sync] Pushing LFS clean matrix up to GitHub..."
        if git push --set-upstream origin "$BRANCH" --force; then
            echo "[Git Sync Complete] Cycle ${CYCLE_ID} published successfully."
        else
            echo "❌ Force push sync frame failed."
        fi
    else
        echo "⚠️ [Warning] Run conditions unfulfilled. Skipping Git synchronization sync frame."
    fi

    # Clears temporary source data but leaves index mappings intact to keep Herbie performance optimal
    find "$SCRATCH_DIR" -type f ! -name "*.idx" -delete 2>/dev/null

    echo "[Cycle Complete] Sleeping for $((CHECK_INTERVAL / 60)) minutes..."
    sleep "$CHECK_INTERVAL"
done