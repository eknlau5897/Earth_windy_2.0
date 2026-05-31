 function initDemoMap() {
            var Esri_WorldImagery = L.tileLayer(
                "http://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
                { attribution: "Tiles &copy; Esri &mdash; Source: Esri" }
            );

            var Esri_DarkGreyCanvas = L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
                attribution: '&copy; OpenStreetMap contributors &copy; CARTO',
                maxZoom: 20
            });

            var StreetMap = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
                attribution: '&copy; OpenStreetMap contributors'
            });

            var baseLayers = {
                "Satellite": Esri_WorldImagery,
                "Dark Canvas": Esri_DarkGreyCanvas,
                "Street Map": StreetMap 
            };

            var map = L.map("map", {
                layers: [Esri_DarkGreyCanvas]
            });

            var layerControl = L.control.layers(baseLayers);
            layerControl.addTo(map);
            map.setView([22.3, 114.17], 5);

            return { map: map, layerControl: layerControl };
        }

        var mapStuff = initDemoMap();
        var map = mapStuff.map;
        var layerControl = mapStuff.layerControl;

        // =========================================================================
        // MAP CLICK POPUP ENGINE (WIND VELOCITY EXTRACTOR)
        // =========================================================================
        map.on('click', function(e) {
            const velocityControl = document.querySelector('.leaflet-control-velocity');
            if (velocityControl && velocityControl.innerText.trim() !== "") {
                const rawText = velocityControl.innerText.trim();
                if (!rawText.includes("No velocity data") && !rawText.includes("No wind data")) {
                    const cleanHtml = rawText
                        .replace("Wind Info:", "<strong>💨 Wind Info</strong>")
                        .replace("Global Wind:", "<strong>💨 Global Wind</strong>")
                        .replace("GFS Wind:", "<strong>💨 GFS Wind</strong>")
                        .replace("GFS 850hPa Wind:", "<strong>💨 GFS 850hPa Wind</strong>")
                        .replace("ECMWF 10m Wind:", "<strong>💨 ECMWF 10m Wind</strong>")
                        .replace(/,\s*/g, "<br/>")  
                        .replace(/Direction:\s*/, "<b>Direction:</b> ")
                        .replace(/Speed:\s*/, "<b>Speed:</b> ");

                    L.popup()
                        .setLatLng(e.latlng)
                        .setContent(`<div style="font-family: Arial, sans-serif; padding: 4px; min-width: 140px; color: #333; line-height: 1.4;">${cleanHtml}</div>`)
                        .openOn(map);
                    return;
                }
            }
            L.popup()
                .setLatLng(e.latlng)
                .setContent('<div style="font-family: Arial, sans-serif; padding: 4px; color: #333;">No wind data available here.</div>')
                .openOn(map);
        });

        // Load Coastlines
        fetch('https://d2ad6b4ur7yvpq.cloudfront.net/naturalearth-3.3.0/ne_110m_coastline.geojson')
            .then(response => response.json())
            .then(data => {
                L.geoJSON(data, { style: { color: '#ffffff', weight: 2, opacity: 0.6 } }).addTo(map);
            });

        // =========================================================================
        // GLOBAL SETTINGS & SYSTEM STATES
        // =========================================================================
        const hours = [];
        for (let h = 0; h <= 240; h += 6) {
            if (h > 120 && h % 12 !== 0) continue;
            hours.push(h.toString().padStart(3, '0'));
        }

        let currentRainLayerType = null; 
        window.activeRainLayer = null;   
        let vLayer = null;               
        let playTimer = null;            
        let satLayerActive = false;       

        // Bind DOM Elements
        const slider = document.getElementById('slider');
        const modelSelect = document.getElementById('modelSelect');
        const hourLabel = document.getElementById('hourLabel'); 
        const statusDisplay = document.getElementById('statusDisplay'); 
        const playBtn = document.getElementById('playBtn');
        const liveRadarBtn = document.getElementById('liveRadarBtn'); 
        const iconBtn = document.getElementById('iconBtn'); 
        const satBtn = document.getElementById('satBtn');

        if (slider) {
            slider.min = "0";
            slider.max = (hours.length - 1).toString(); 
        }

        // =========================================================================
        // CORE MAP & DATA REFRESH ENGINE (PARTICLE CANVAS DRIVER)
        // =========================================================================
        // Helper function to format the ISO string into a beautiful readable date
function formatForecastTime(refTimeStr, forecastHours) {
    // Parse the reference run time (e.g., "2026-05-31T00:00:00.000Z")
    const refDate = new Date(refTimeStr);
    
    // Add the forecast hours to the reference time
    refDate.setHours(refDate.getHours() + parseInt(forecastHours, 10));
    
    // Format options: "Sunday, May 31, 2026, 3:00 PM"
    return refDate.toLocaleString(undefined, {
        weekday: 'short',
        month: 'short',
        day: 'numeric',
        year: 'numeric',
        hour: '2-digit',
        minute: '2-digit'
    });
}

async function updateMap() {
    const index = slider.value;
    const h = hours[index];
    const selectedModel = modelSelect.value;

    // Clear active dynamic tracking overlay to prevent frame overlap leaks
    if (vLayer) { map.removeLayer(vLayer); vLayer = null; }

    // Sync multi-source precipitation loops
    let gfsRainPath = `../data/gfs_rain_f${h}.json`;
    await handlePrecipitationPipelines(gfsRainPath);

    // Determine local data path based on layer selection options
    let windPath = `../data/gfs_f${h}.json`;
    if (selectedModel === "GFS 850hPa") {
        windPath = `../data/gfs_850_f${h}.json`;
    } else if (selectedModel === "ECMWF 10m") {
        windPath = `../data/ecmwf_10m_f${h}.json`;
    }

    if (statusDisplay) statusDisplay.innerHTML = `Loading vector matrix: ${windPath}...`;

    try {
        const res = await fetch(windPath);
        if (!res.ok) throw new Error("Data asset file missing or updates in progress");
        const data = await res.json();

        // =========================================================================
        // DYNAMIC TIME ENGINE EXTRACTOR
        // =========================================================================
        // Extract the refTime embedded in the header generated by your Python script
        const referenceTime = data[0].header.refTime; 
        const humanReadableTime = formatForecastTime(referenceTime, h);

        // Update the timeline label with both the step hours AND the true valid date
        if (hourLabel) {
            hourLabel.innerHTML = `+${h}h <br><span style="color: #00ceff; font-size: 14px;">📅 ${humanReadableTime}</span>`;
        }

        // Generate particle wind canvas string overlay
        vLayer = L.velocityLayer({
            displayValues: true,
            displayOptions: { velocityType: `${selectedModel} Wind`, displayPosition: 'bottomleft' },
            data: data,
            minVelocity: 0,
            maxVelocity: 70, 
            velocityScale: 0.005,
            particleMultiplier: 1 / 100,
            colorScale: [
                "rgba(0, 0, 144, 0.9)", "rgba(0, 0, 255, 0.9)", "rgba(0, 130, 255, 0.9)",
                "rgba(0, 190, 190, 0.9)", "rgba(0, 220, 0, 0.9)", "rgba(130, 230, 0, 0.9)",
                "rgba(240, 240, 0, 0.9)", "rgba(255, 170, 0, 0.9)", "rgba(255, 0, 0, 0.9)",
                "rgba(200, 0, 0, 0.9)", "rgba(255, 0, 255, 0.9)", "rgba(160, 32, 240, 0.9)",
                "rgba(255, 255, 255, 0.9)"
            ]
        });
        
        vLayer.addTo(map);
        
        if (satLayerActive && map.hasLayer(himawariWorldview)) {
            map.removeLayer(himawariWorldview);
            himawariWorldview.addTo(map);
        }

        if (statusDisplay) {
            statusDisplay.innerHTML = `MODEL: ${selectedModel}\nRUN: ${referenceTime}\nVALID: ${humanReadableTime}\nSTATUS: Live Data Active`;
        }

    } catch (err) {
        if (statusDisplay) {
            statusDisplay.innerHTML = `⚠️ ERROR: ${err.message}`;
        }
    }
}

        // =========================================================================
        // MULTI-SOURCE PRECIPITATION ROUTER ENGINE
        // =========================================================================
        async function handlePrecipitationPipelines(gfsRainPath) {
            if (liveRadarBtn) liveRadarBtn.classList.remove('active');
            if (iconBtn) iconBtn.classList.remove('active');

            if (window.activeRainLayer) {
                map.removeLayer(window.activeRainLayer);
                window.activeRainLayer = null;
            }

            if (!currentRainLayerType) return;

            if (currentRainLayerType === 'gfs_rain') {
                if (iconBtn) iconBtn.classList.add('active');
                await renderGfsRainCanvas(gfsRainPath);
            } 
            else if (currentRainLayerType === 'rv_live') {
                if (liveRadarBtn) liveRadarBtn.classList.add('active');

                try {
                    const res = await fetch('https://api.rainviewer.com/public/weather-maps.json');
                    const data = await res.json();
                    
                    if (data.radar && data.radar.past && data.radar.past.length > 0) {
                        const targetFrame = data.radar.past[data.radar.past.length - 1];
                        const tileUrl = `${data.host}${targetFrame.path}/1024/{z}/{x}/{y}/2/1_1.png`;
                        
                        window.activeRainLayer = L.tileLayer(tileUrl, {
                            opacity: 0.60,
                            zIndex: 100,
                            maxNativeZoom: 6,  
                            maxZoom: 20
                        }).addTo(map);
                    }
                } catch (err) {
                    console.error("Failed to query RainViewer API assets:", err);
                }
            }
        }

        // =========================================================================
        // NATIVE GFS APCP GRID LAYER (CANVAS RENDERER)
        // =========================================================================
        async function renderGfsRainCanvas(filePath) {
            try {
                const res = await fetch(filePath);
                if (!res.ok) throw new Error("Rain map asset unreadable");
                const gribData = await res.json();
                
                const header = gribData[0].header;
                const rainValues = gribData[0].data; 

                const nx = header.nx; const ny = header.ny;
                const lo1 = header.lo1; const la1 = header.la1;
                const dx = header.dx; const dy = header.dy;

                const GfsCanvasLayer = L.GridLayer.extend({
                    createTile: function(coords) {
                        const tile = L.DomUtil.create('canvas', 'leaflet-tile');
                        const size = this.getTileSize();
                        tile.width = size.x;
                        tile.height = size.y;
                        const ctx = tile.getContext('2d');
                        const nwPoint = coords.scaleBy(size);
                        
                        for (let y = 0; y < size.y; y += 3) { 
                            for (let x = 0; x < size.x; x += 3) {
                                const mapPoint = L.point(nwPoint.x + x, nwPoint.y + y);
                                const latlng = map.unproject(mapPoint, coords.z);
                                
                                let lon = latlng.lng;
                                if (lon < 0) lon += 360; 
                                
                                const col = Math.floor((lon - lo1) / dx);
                                const row = Math.floor((la1 - latlng.lat) / dy);

                                if (col >= 0 && col < nx && row >= 0 && row < ny) {
                                    const index = row * nx + col;
                                    const mmValue = rainValues[index];

                                    if (mmValue > 0.1) {
                                        ctx.fillStyle = getRainColorScale(mmValue);
                                        ctx.fillRect(x, y, 3, 3);
                                    }
                                }
                            }
                        }
                        return tile;
                    }
                });

                window.activeRainLayer = new GfsCanvasLayer({ opacity: 0.55, zIndex: 90 });
                window.activeRainLayer.addTo(map);

            } catch (err) {
                console.error("GFS Local Precipitation processor aborted:", err);
            }
        }

        function getRainColorScale(val) {
            if (val <= 0.1) return "rgba(0, 0, 0, 0)"; 
            const maxVal = 50;
            const normalized = Math.min(val / maxVal, 1.0); 

            const anchors = [
                { pct: 0.00, r: 0,   g: 0,   b: 180, a: 0.35 }, 
                { pct: 0.15, r: 0,   g: 120, b: 255, a: 0.50 }, 
                { pct: 0.30, r: 0,   g: 200, b: 100, a: 0.60 }, 
                { pct: 0.45, r: 160, g: 230, b: 0,   a: 0.65 }, 
                { pct: 0.60, r: 255, g: 200, b: 0,   a: 0.70 }, 
                { pct: 0.75, r: 255, g: 60,  b: 0,   a: 0.80 }, 
                { pct: 0.90, r: 180, g: 0,   b: 180, a: 0.85 }, 
                { pct: 1.00, r: 255, g: 255, b: 255, a: 0.90 }  
            ];

            let lower = anchors[0];
            let upper = anchors[anchors.length - 1];

            for (let i = 0; i < anchors.length - 1; i++) {
                if (normalized >= anchors[i].pct && normalized <= anchors[i + 1].pct) {
                    lower = anchors[i];
                    upper = anchors[i + 1];
                    break;
                }
            }

            const range = upper.pct - lower.pct;
            const rangePct = range === 0 ? 0 : (normalized - lower.pct) / range;

            const r = Math.round(lower.r + (upper.r - lower.r) * rangePct);
            const g = Math.round(lower.g + (upper.g - lower.g) * rangePct);
            const b = Math.round(lower.b + (upper.b - lower.b) * rangePct);
            const a = (lower.a + (upper.a - lower.a) * rangePct).toFixed(2);

            return `rgba(${r}, ${g}, ${b}, ${a})`;
        }

        // =========================================================================
        // ACTION ROUTERS & UI INTERACTION WATCHERS
        // =========================================================================
        if (iconBtn) {
            iconBtn.onclick = function() {
                currentRainLayerType = (currentRainLayerType === 'gfs_rain') ? null : 'gfs_rain';
                updateMap();
            };
        }

        if (liveRadarBtn) {
            liveRadarBtn.onclick = function() {
                currentRainLayerType = (currentRainLayerType === 'rv_live') ? null : 'rv_live';
                updateMap();
            };
        }

        if (slider) slider.oninput = () => updateMap();
        if (modelSelect) modelSelect.onchange = () => updateMap();

        if (playBtn) {
            playBtn.onclick = function() {
                if (playTimer) {
                    clearInterval(playTimer); 
                    playTimer = null; 
                    this.innerText = "Play Animation";
                    this.classList.remove('active');
                } else {
                    this.innerText = "Pause Animation";
                    this.classList.add('active');
                    playTimer = setInterval(() => {
                        let nextIndex = (parseInt(slider.value) + 1) % hours.length;
                        slider.value = nextIndex;
                        updateMap();
                    }, 1500);
                }
            };
        }

        // =========================================================================
        // NASA GIBS WMTS SATELLITE LAYER SETUP
        // =========================================================================
        const targetTime = new Date();
        targetTime.setMinutes(targetTime.getMinutes() - 60);
        const mins = targetTime.getMinutes();
        targetTime.setMinutes(mins - (mins % 10));
        targetTime.setSeconds(0);
        targetTime.setMilliseconds(0);
        const exactTimeStr = targetTime.toISOString().replace('.000Z', 'Z');

        var himawariWorldview = L.tileLayer('https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/' +
            'Himawari_AHI_Band13_Clean_Infrared/default/' +
            '{time}/GoogleMapsCompatible_Level6/{z}/{y}/{x}.png', {
            time: exactTimeStr, 
            tileSize: 256,
            transparent: true,
            opacity: 0.75,
            attribution: 'Imagery &copy; NASA GIBS / JMA',
            maxNativeZoom: 6,
            maxZoom: 20,
            zIndex: 10,
            keepBuffer: 4,
            updateWhenIdle: false,
            crossOrigin: true
        });

        if (satBtn) {
            satBtn.onclick = function() {
                if (satLayerActive) {
                    map.removeLayer(himawariWorldview);
                    satBtn.classList.remove('active');
                    satBtn.innerText = "IR Satellite: Off";
                    satLayerActive = false;
                } else {
                    himawariWorldview.addTo(map);
                    satBtn.classList.add('active');
                    satBtn.innerText = "IR Satellite: On";
                    satLayerActive = true;
            
                    if (vLayer && map.hasLayer(vLayer)) { 
                        map.removeLayer(vLayer);
                        vLayer.addTo(map); 
                    }
                }
            };
        }

        // Initial Map Frame Render
        updateMap();