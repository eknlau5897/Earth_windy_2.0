#!/bin/bash
$BRANCH="main" # Default to main if not set
# Configuration
GRIB2JSON="/opt/homebrew/bin/grib2json"
BRANCH="${BRANCH:-main}" # Default to main if not set
export JAVA_HOME=$(/usr/libexec/java_home)
export PATH=$JAVA_HOME/bin:$PATH

# Define function BEFORE calling it
old_date() {
    CYCLE="18"
    # macOS/BSD date syntax
    DATE=$(date -u -v-1d +%Y%m%d)
}

while true; do
    git pull origin "$BRANCH" --rebase

    CURRENT_HOUR=$(date -u +%H)
    DATE=$(date -u +%Y%m%d)

    # Logic to pick the last available 6-hour cycle (with processing delay buffer)
    if [ "$CURRENT_HOUR" -ge 23 ]; then
        CYCLE="18"
    elif [ "$CURRENT_HOUR" -ge 17 ]; then
        CYCLE="12"
    elif [ "$CURRENT_HOUR" -ge 11 ]; then
        CYCLE="06"
    elif [ "$CURRENT_HOUR" -ge 5 ]; then
        CYCLE="00"
    else
        old_date
    fi

    mkdir -p data

    for (( fhr=0; fhr<=240; fhr+=6 ))
    do
        # Skip logic for long-range forecasts
        if [ "$fhr" -gt 120 ] && [ $((fhr % 12)) -ne 0 ]; then continue; fi

        # NOAA requires 3 digits (e.g., 006, 012, 120)
        FILE_FHR=$(printf "%03d" "$fhr")

        GRIB="temp_${FILE_FHR}.grib2"
        JSON="data/gfs_f${FILE_FHR}.json"

        echo "📥 Downloading GFS ${DATE} ${CYCLE}z +${FILE_FHR}h..."
    
        URL="https://nomads.ncep.noaa.gov/cgi-bin/filter_gfs_0p25.pl?file=gfs.t${CYCLE}z.pgrb2.0p25.f${FILE_FHR}&var_UGRD=on&var_VGRD=on&lev_100_m_above_ground=on&dir=%2Fgfs.${DATE}%2F${CYCLE}%2Fatmos"
    
        curl -f -s "$URL" -o "$GRIB"

        if [ -s "$GRIB" ]; then
            echo "📦 Converting to JSON..."
            JAVA_OPTS="-Xmx4g" "$GRIB2JSON" -d -c -n --fp 2 jq -c '(.data[]) |= (.*100 | round / 100)' "$GRIB"> "$JSON"
            rm -f "$GRIB"
        else
            echo "⚠️  Forecast +${FILE_FHR} not available yet."
            rm -f "$GRIB"
        fi
    done

    echo "✅ Update Complete."
    git add data/*.json
    git commit -m "Update GFS data: ${DATE} ${CYCLE}z"
    git push origin "$BRANCH"
    
    echo "Waiting 6 hours..."
    sleep 21600
done