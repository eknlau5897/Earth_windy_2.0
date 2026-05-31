#!/bin/bash

# =========================================================================
# GLOBAL RUNTIME CONFIGURATION
# =========================================================================
#!/bin/bash
set -e

BRANCH="main"
BRANCH="${BRANCH:-main}" 

old_date() {
    CYCLE="12" 
    # Dual-compatibility fallback for macOS and Linux date calculations
    DATE=$(date -v-1d "+%Y-%m-%d" 2>/dev/null || date -d "1 day ago" "+%Y-%m-%d")
}

# =========================================================================
# SYSTEM DAEMON LOOP
# =========================================================================
while true; do
    echo "🔄 Pulling upstream updates to keep repository synced..."
    # Keep history completely safe by rebasing incoming remote changes cleanly
    git pull origin "$BRANCH" --rebase || echo "First run or branch detached; continuing..."

    CURRENT_HOUR=$(date -u +%H)
    DATE=$(date -u +"%Y-%m-%d")

    # ECMWF Open Data availability configuration cushion window
    if [ "$CURRENT_HOUR" -ge 20 ]; then
        CYCLE="12"
    elif [ "$CURRENT_HOUR" -ge 8 ]; then
        CYCLE="00"
    else
        old_date
    fi

    mkdir -p data

    # Loop through forecast hours (0 to 240)
    for (( fhr=0; fhr<=240; fhr+=6 ))
    do
        # Skip long-range steps to optimize payload footprint (matches your UI timelines)
        if [ "$fhr" -gt 120 ] && [ $((fhr % 12)) -ne 0 ]; then continue; fi

        FILE_FHR=$(printf "%03d" "$fhr")
        FINAL_JSON="data/ecmwf_10m_f${FILE_FHR}.json"

        echo "📥 Herbie Pipeline Active: Fetching ECMWF Open Data (${DATE} ${CYCLE}z +${fhr}h)..."
        
        # =========================================================================
        # INLINE EMBEDDED PYTHON HERBIE COMPILER
        # =========================================================================
        python3 - <<EOF
import sys
import json
import numpy as np
import xarray as xr
from herbie import Herbie

try:
    H = Herbie(
        "${DATE} ${CYCLE}:00",
        model="ifs",
        product="oper",
        fxx=${fhr},
        priority=['azure', 'aws', 'ecmwf']
    )
    
    ds_u = H.xarray("10u")
    ds_v = H.xarray("10v")
    
    lon = ds_u.longitude.values
    lat = ds_u.latitude.values
    u_raw = ds_u.u10.values
    v_raw = ds_v.v10.values
    ny, nx = u_raw.shape

    if lon.min() < 0 or lon.max() <= 180:
        half = nx // 2
        u_raw = np.hstack((u_raw[:, half:], u_raw[:, :half]))
        v_raw = np.hstack((v_raw[:, half:], v_raw[:, :half]))
        lo1 = 0.0
        lo2 = 359.75
    else:
        lo1 = float(lon.min())
        lo2 = float(lon.max())

    u_data_list = [round(float(x), 2) for x in u_raw.flatten()]
    v_data_list = [round(float(x), 2) for x in v_raw.flatten()]

    output_payload = [
        {
            "header": {
                "discipline": 0, "disciplineName": "Meteorological products",
                "refTime": "${DATE}T${CYCLE}:00:00.000Z", "nx": nx, "ny": ny,
                "la1": float(lat.max()), "lo1": lo1, "la2": float(lat.min()), "lo2": lo2,
                "dx": 0.25, "dy": 0.25, "parameterCategory": 2,
                "parameterCategoryName": "Momentum", "parameterNumber": 2,
                "parameterName": "U-component of wind", "parameterUnit": "m/s",
                "surface1Type": 103, "surface1TypeName": "Specified height level above ground", "surface1Value": 10.0
            },
            "data": u_data_list
        },
        {
            "header": {
                "discipline": 0, "disciplineName": "Meteorological products",
                "refTime": "${DATE}T${CYCLE}:00:00.000Z", "nx": nx, "ny": ny,
                "la1": float(lat.max()), "lo1": lo1, "la2": float(lat.min()), "lo2": lo2,
                "dx": 0.25, "dy": 0.25, "parameterCategory": 2,
                "parameterCategoryName": "Momentum", "parameterNumber": 3,
                "parameterName": "V-component of wind", "parameterUnit": "m/s",
                "surface1Type": 103, "surface1TypeName": "Specified height level above ground", "surface1Value": 10.0
            },
            "data": v_data_list
        }
    ]

    with open("${FINAL_JSON}", "w") as f:
        json.dump(output_payload, f)
        
    print("✅ Successfully generated conformed GFS-Standard JSON via Herbie.")

except Exception as e:
    print(f"❌ Herbie Pipeline Processing Aborted: {e}", file=sys.stderr)
    sys.exit(1)
EOF
    done

    # =========================================================================
    # DEPLOYMENT STAGE (STANDARD HISTORICAL COMMITS)
    # =========================================================================
    echo "🚀 Staging updated wind telemetry matrices..."
    git add data/ecmwf_10m_f*.json
    
    # Check if there are actual changes before committing to avoid empty commit noise
    if ! git diff-index --quiet HEAD --; then
        echo "📝 Creating new data sync tracking commit..."
        git commit -m "Update weather matrices: ${DATE} ${CYCLE}z run"
        
        echo "📤 Pushing increment updates safely to remote repository branch..."
        git push origin "$BRANCH"
        echo "✅ Sync deployment successfully tracked."
    else
        echo "ℹ️  No changes detected in matrices for this interval frame. Skipping commit."
    fi
    
    echo "💤 Execution frame completed successfully. Sleeping for 12 hours..."
    sleep 43200
done