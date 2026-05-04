function initDemoMap() {
  var Esri_WorldImagery = L.tileLayer(
    "http://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
    {
      attribution: "Tiles &copy; Esri &mdash; Source: Esri, i-cubed, USDA, USGS, AEX, GeoEye, Getmapping, Aerogrid, IGN, IGP, UPR-EGP, and the GIS User Community"
    }
  );

   L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
            attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>',
            maxZoom: 20
        });

  var StreetMap = L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; <a href="https://openstreetmap.org">OpenStreetMap</a> contributors'
  });

  // 底圖選單
  var baseLayers = {
    "Satellite": Esri_WorldImagery,
    "Dark Canvas": Esri_DarkGreyCanvas,
    "Street Map": StreetMap // 這裡保留了街道地圖
  };

  var map = L.map("map", {
    layers: [StreetMap] // 預設開啟 Street Map
  });

  var layerControl = L.control.layers(baseLayers);
  layerControl.addTo(map);
  map.setView([22.3, 114.17], 5);

  return {
    map: map,
    layerControl: layerControl
  };
}

var mapStuff = initDemoMap();
var map = mapStuff.map;
var layerControl = mapStuff.layerControl;

// --- 載入海岸線 ---
fetch('https://d2ad6b4ur7yvpq.cloudfront.net/naturalearth-3.3.0/ne_110m_coastline.geojson')
    .then(response => response.json())
    .then(data => {
        L.geoJSON(data, {
            style: { color: '#ffffff', weight: 2, opacity: 0.6 }
        }).addTo(map);
    });

// --- 時間軸設定 ---
const hours = [];
for (let h = 0; h <= 240; h += 6) {
    if (h > 120 && h % 12 !== 0) continue;
    hours.push(h.toString().padStart(3, '0'));
}

const slider = document.getElementById('slider');
const label = document.getElementById('label');
const playBtn = document.getElementById('playBtn');
const modelSelect = document.getElementById('modelSelect'); // 假設 HTML 有這個下拉選單

if (slider) slider.max = hours.length - 1;

let vLayer = null; // 全域變數，用來追蹤當前的風場圖層

async function updateMap() {
    const index = slider.value;
    const h = hours[index];
    const selectedModel = modelSelect ? modelSelect.value : "GFS"; // 取得當前選擇的模型
    
    if (label) label.innerText = `${selectedModel} Forecast: +${h}h`;

    // 根據選擇的模型動態決定路徑
    let filePath = selectedModel === "GFS" ? `../data/gfs_f${h}.json` : `../data/other_f${h}.json`;

    try {
        const res = await fetch(filePath);
        if (!res.ok) throw new Error("File not found");
        const data = await res.json();

        // 【關鍵：互斥邏輯】
        // 每次更新前，如果地圖上已經有 vLayer，就先移除它，確保不重疊
        if (vLayer) {
            map.removeLayer(vLayer);
        }

        // 重新建立新的 Velocity Layer
        vLayer = L.velocityLayer({
            displayValues: true,
            displayOptions: { 
                velocityType: `${selectedModel} Wind`, 
                displayPosition: 'bottomleft' 
            },
            data: data,
            maxVelocity: 25,
            velocityScale: 0.005,
            particleMultiplier: 1/100 
        });

        vLayer.addTo(map);
        
    } catch (err) {
        console.warn(`Data not ready: ${filePath}`);
    }
}

// 監聽事件
if (slider) slider.oninput = () => updateMap();
if (modelSelect) modelSelect.onchange = () => updateMap();

// 播放按鈕邏輯
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
                updateMap();
            }, 1500);
        }
    };
}

// 初始化啟動
updateMap();
