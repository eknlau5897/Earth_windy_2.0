function initDemoMap() {
  var Esri_WorldImagery = L.tileLayer(
    "http://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
    {
      crs:L.CRS.ESPG4326,
      attribution:
        "Tiles &copy; Esri &mdash; Source: Esri, i-cubed, USDA, USGS, " +
        "AEX, GeoEye, Getmapping, Aerogrid, IGN, IGP, UPR-EGP, and the GIS User Community"
    }
  );

  var Esri_DarkGreyCanvas = L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
    crs:L.CRS.ESPG4326,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>',
    maxZoom: 20});
  var StreetMap =   L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
    })

  var baseLayers = {
    Satellite: Esri_WorldImagery,
    "OSM map": Esri_DarkGreyCanvas,
    "Street Map": StreetMap
  };

  var map = L.map("map", {
    layers: [Esri_WorldImagery]
  });

  var layerControl = L.control.layers(baseLayers);
  layerControl.addTo(map);
  map.setView([22.3, 114.17], 5);

  return {
    map: map,
    layerControl: layerControl
  };
}

// demo map

var mapStuff = initDemoMap();
var map = mapStuff.map;
var layerControl = mapStuff.layerControl;
fetch('https://d2ad6b4ur7yvpq.cloudfront.net/naturalearth-3.3.0/ne_110m_coastline.geojson')
    .then(response => response.json())
    .then(data => {
        L.geoJSON(data, {
            style: {
                color: 'rgb(247, 243, 243)',   // Line color
                weight: 2,       // Line thickness
                opacity: 0.8     // Transparency
            }
        }).addTo(map);
    });
// --- GFS TIMELINE LOGIC ---

const hours = []; // Ensure this is initialized exactly like this
for (let h = 0; h <= 240; h += 6) {
    if (h > 120 && h % 12 !== 0) continue;
    hours.push(h.toString().padStart(3, '0'));
}

// Get UI elements
const slider = document.getElementById('slider');
const label = document.getElementById('label');
const playBtn = document.getElementById('playBtn');

if (slider) slider.max = hours.length - 1;

let vLayer = null;

async function updateMap(index) {
    const h = hours[index];
    if (label) label.innerText = `Forecast: +${h}h`;

    try {
        const res = await fetch(`../data/gfs_f${h}.json`);
        if (!res.ok) throw new Error("File not found");
        const data = await res.json();

        if (!data || data.length < 2) return;

        if (!vLayer) {
            vLayer = L.velocityLayer({
                displayValues: true,
                displayOptions: { 
                    velocityType: 'Global Wind', 
                    displayPosition: 'bottomleft' 
                },
                data: data,
                maxVelocity: 25,
                velocityScale: 0.005,
                particleMultiplier: 1/100 
            }).addTo(map);
            
            // Optional: Add to layer control so you can toggle it
            layerControl.addOverlay(vLayer, "GFS 100m wind Forecast, update every 01Z, 07Z, 13Z, 19Z");
        } else {
            vLayer.setData(data); 
        }
    } catch (err) {
        console.warn(`Data not ready: gfs_f${h}.json`);
    }
}

// UI Event Listeners
if (slider) {
    slider.oninput = (e) => updateMap(e.target.value);
}

let playTimer = null;
if (playBtn) {
    playBtn.onclick = function() {
        if (playTimer) {
            clearInterval(playTimer); 
            playTimer = null; 
            this.innerText = "Play";
        } else {
            this.innerText = "Pause";
            playTimer = setInterval(() => {
                let nextIndex = (parseInt(slider.value) + 1) % hours.length;
                slider.value = nextIndex;
                updateMap(nextIndex);
            }, 1500);
        }
    };
}

// Start with hour 0
updateMap(0);