#!/usr/bin/env bash
set -euo pipefail # Fail-fast shell architecture

OUTPUT_DIR="./data"
SCRATCH_DIR="./.tmp_scratch"
CWA_INPUT_DIR="/Users/eknlau/Desktop/CWA/accu_rain/"  # Verified path
CHECK_INTERVAL=43200 

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
echo "   HERBIE + CWA XARRAY NATIVE DAEMON ENGINE v14"
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

    if [ "$CURRENT_HOUR" -ge 12 ] && [ "$CURRENT_HOUR" -lt 24 ]; then
        GFS_CYCLE="00"; GFS_DATE="${CURRENT_DATE} 00:00"
        IFS_CYCLE="00"; IFS_DATE="${CURRENT_DATE} 00:00"
        AIFS_CYCLE="00"; AIFS_DATE="${CURRENT_DATE} 00:00"
        CWA_DATE="${CURRENT_DATE} 00:00"

    elif [ "$CURRENT_HOUR" -ge 0 ] && [ "$CURRENT_HOUR" -lt 12 ]; then
        GFS_CYCLE="12"; GFS_DATE="${YESTERDAY} 12:00"
        IFS_CYCLE="12"; IFS_DATE="${YESTERDAY} 12:00"
        AIFS_CYCLE="12"; AIFS_DATE="${YESTERDAY} 12:00"
        CWA_DATE="${YESTERDAY} 12:00"
    fi

    # Mirroring CWA WRF runtime calculation exactly from your web client logic

    export GFS_DATE; export IFS_DATE; export AIFS_DATE; export CWA_DATE
    export SCRATCH_DIR; export CWA_INPUT_DIR

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
from datetime import datetime, timedelta
from herbie import Herbie

gfs_date_env = os.environ.get("GFS_DATE")
ifs_date_env = os.environ.get("IFS_DATE")
aifs_date_env = os.environ.get("AIFS_DATE")
cwa_date_env = os.environ.get("CWA_DATE")
clean_hour_env = int(os.environ.get("CLEAN_HOUR", 0))
fhr_env = os.environ.get("fhr")
scratch_dir = os.environ.get("SCRATCH_DIR", "./.tmp_scratch")
cwa_input_dir = os.environ.get("CWA_INPUT_DIR", "./cwa_raw_folder")

def get_time_strings(base_date_str, fhr_int):
    """Calculates explicit ISO strings for baseline run and forecast target validity."""
    if not base_date_str:
        return "N/A", "N/A"
    try:
        base_dt = datetime.strptime(base_date_str, "%Y-%m-%d %H:%M")
        valid_dt = base_dt + timedelta(hours=fhr_int)
        return base_dt.strftime("%Y-%m-%d %H:%M UTC"), valid_dt.strftime("%Y-%m-%d %H:%M UTC")
    except Exception:
        return base_date_str, "N/A"

def build_json(param, level, ds, u_var, v_var=None, is_pressure_level=False, base_date_str=None):
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
            if p_coord and len(u_vals.shape) > 2:
                p_array = list(np.atleast_1d(ds[p_coord].values))
                target = level * 100 if p_coord == 'plev' else level
                if target in p_array:
                    idx = p_array.index(target)
                    u_vals = u_vals[idx]
                    v_vals = v_vals[idx]

        if len(lats.shape) == 1 and lats[0] < lats[-1]:
            u_vals = np.flipud(u_vals)
            if v_var: v_vals = np.flipud(v_vals)
        elif len(lats.shape) > 1 and lats[0,0] < lats[-1,0]:
            u_vals = np.flipud(u_vals)
            if v_var: v_vals = np.flipud(v_vals)

        run_time, valid_time = get_time_strings(base_date_str, clean_hour_env)

        if v_var is None:
            return {
                "header": {
                    "parameterName": "Mean Sea Level Pressure", 
                    "surface1Value": 0, "nx": nx, "ny": ny, 
                    "lo1": float(lons.min()), "la1": float(lats.max()), 
                    "lo2": float(lons.max()), "la2": float(lats.min()), 
                    "dx": 0.25, "dy": 0.25,
                    "refTime": run_time,
                    "validTime": valid_time
                }, 
                "data": np.where(np.isnan(u_vals), 101325, u_vals).flatten().tolist()
            }

        return [
            {"header": {"parameterName": "U-component of wind", "surface1Value": level, "nx": nx, "ny": ny, "lo1": float(lons.min()), "la1": float(lats.max()), "lo2": float(lons.max()), "la2": float(lats.min()), "dx": 0.25, "dy": 0.25, "refTime": run_time, "validTime": valid_time}, "data": np.where(np.isnan(u_vals), 0, u_vals).flatten().tolist()},
            {"header": {"parameterName": "V-component of wind", "surface1Value": level, "nx": nx, "ny": ny, "lo1": float(lons.min()), "la1": float(lats.max()), "lo2": float(lons.min()), "la2": float(lats.min()), "dx": 0.25, "dy": 0.25, "refTime": run_time, "validTime": valid_time}, "data": np.where(np.isnan(v_vals), 0, v_vals).flatten().tolist()}
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
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(Hg, ":(U|V)GRD:10 m above ground:"), "u10", "v10", base_date_str=gfs_date_env), f"gfs_10m_f{fhr_env}.json.gz")
    
    gfs_mslp = safe_xarray_fetch(Hg, ":PRMSL:mean sea level:")
    if gfs_mslp is not None:
        mslp_var = "prmsl" if "prmsl" in gfs_mslp.data_vars else list(gfs_mslp.data_vars)[0]
        save_gzip(build_json("MSLP", 0, gfs_mslp, mslp_var, None, base_date_str=gfs_date_env), f"gfs_mslp_f{fhr_env}.json.gz")

    for p in [850, 700, 500, 200]:
        gfs_plev_ds = safe_xarray_fetch(Hg, f":(U|V)GRD:{p} mb:")
        if gfs_plev_ds is not None:
            gfs_u = "u" if "u" in gfs_plev_ds.data_vars else "ugrd"
            gfs_v = "v" if "v" in gfs_plev_ds.data_vars else "vgrd"
            save_gzip(build_json("Wind", p, gfs_plev_ds, gfs_u, gfs_v, is_pressure_level=True, base_date_str=gfs_date_env), f"gfs_{p}_f{fhr_env}.json.gz")
except Exception as e: print(f"GFS Skip: {e}")

try:
    He = Herbie(ifs_date_env, model="ifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False)
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(He, ":10(u|v):"), "u10", "v10", base_date_str=ifs_date_env), f"ecmwf_10m_f{fhr_env}.json.gz")
    
    ifs_mslp = safe_xarray_fetch(He, ":msl:")
    if ifs_mslp is not None:
        mslp_var = "msl" if "msl" in ifs_mslp.data_vars else list(ifs_mslp.data_vars)[0]
        save_gzip(build_json("MSLP", 0, ifs_mslp, mslp_var, None, base_date_str=ifs_date_env), f"ecmwf_mslp_f{fhr_env}.json.gz")

    for p in [850, 700, 500, 200]:
        save_gzip(build_json("Wind", p, safe_xarray_fetch(He, f":(u|v):{p}:"), "u", "v", True, base_date_str=ifs_date_env), f"ecmwf_{p}_f{fhr_env}.json.gz")
except Exception as e: print(f"IFS Skip: {e}")

try:
    Ha = Herbie(aifs_date_env, model="aifs", product="oper", source="ecmwf", fxx=clean_hour_env, verbose=False)
    save_gzip(build_json("Wind", 10, safe_xarray_fetch(Ha, ":10(u|v):"), "u10", "v10", base_date_str=aifs_date_env), f"aifs_10m_f{fhr_env}.json.gz")
    
    aifs_mslp = safe_xarray_fetch(Ha, ":msl:")
    if aifs_mslp is not None:
        mslp_var = "msl" if "msl" in aifs_mslp.data_vars else list(aifs_mslp.data_vars)[0]
        save_gzip(build_json("MSLP", 0, aifs_mslp, mslp_var, None, base_date_str=aifs_date_env), f"aifs_mslp_f{fhr_env}.json.gz")

    for p in [850, 700, 500, 200]:
        save_gzip(build_json("Wind", p, safe_xarray_fetch(Ha, f":(u|v):{p}:"), "u", "v", True, base_date_str=aifs_date_env), f"aifs_{p}_f{fhr_env}.json.gz")
except Exception as e: print(f"AIFS Skip: {e}")


# --- TAIWAN CWA WRF NATIVE ENGINE ---
if fhr_env == "000":
    print(f"ℹ️ Skipping step f000 for CWA WRF (Native operational products begin at f006).")
elif clean_hour_env <= 84:
    raw_grib_name = f"{fhr_env}.grb2"
    grib_target_path = os.path.join(cwa_input_dir, raw_grib_name)

    if os.path.exists(grib_target_path):
        try:
            import cfgrib
            datasets = cfgrib.open_datasets(grib_target_path)
            
            ds_surface = datasets[0]
            cwa_10m_json = build_json("Wind", 10, ds_surface, "u10", "v10", base_date_str=cwa_date_env)
            save_gzip(cwa_10m_json, f"cwawrf_10m_f{fhr_env}.json.gz")
            
            ds_pressure = datasets[2]
            level_mappings = {850: 2, 700: 3, 500: 4, 200: 8}
            
            for p_level, idx in level_mappings.items():
                try:
                    ds_slice = ds_pressure.isel(isobaricInhPa=idx)
                    cwa_p_json = build_json("Wind", p_level, ds_slice, "u", "v", is_pressure_level=False, base_date_str=cwa_date_env)
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

        # FIXED EXPLICIT CONDITIONAL: 
        # Only migrate files if Python actually generated data inside the workspace.
        # This keeps empty configurations from breaking your web client's header loops.
        if [ -n "$(find "$SCRATCH_DIR" -maxdepth 1 -name "*.json.gz" -print -quit)" ]; then
            find "$SCRATCH_DIR" -type f -name "*.json.gz" -exec mv -f {} "$OUTPUT_DIR/" \;
        else
            echo "⚠️ [Pipeline Warning] No payload generated for forecast step f${fhr}. Keeping cache intact."
            DATA_ERROR_OCCURRED=1
        fi
    done

    # Clean transient files
    find "$CWA_INPUT_DIR" -type f -name "*.idx" -delete 2>/dev/null
    find "$SCRATCH_DIR" -type f -delete 2>/dev/null
    
    if [ "$DATA_ERROR_OCCURRED" -eq 0 ]; then
        touch "$success_lockfile"
        echo "✅ [Cycle Complete] All forecast targets verified and published."
    else
        echo "⚠️ [Cycle Finished with partial errors] Lockfile suspended. Retrying next loop."
    fi
    
    echo "Sleeping for next interval..."
    sleep "$CHECK_INTERVAL"
done