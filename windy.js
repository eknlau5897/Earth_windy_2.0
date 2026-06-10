/*  Global class for simulating the movement of particle through a 1km wind grid

 credit: All the credit for this work goes to: https://github.com/cambecc for creating the repo:
 https://github.com/cambecc/earth. The majority of this code is directly take nfrom there, since its awesome.

 This class takes a canvas element and an array of data (1km GFS from http://www.emc.ncep.noaa.gov/index.php?branch=GFS)
 and then uses a mercator (forward/reverse) projection to correctly map wind vectors in "map space".

 The "start" method takes the bounds of the map at its current extent and starts the whole gridding,
 interpolation and animation process.
 */

var Windy = function(params) {
  // 1 knot to 150 knots converted cleanly into meters per second (m/s) under the hood
  // 1 kt = 0.514 m/s  |  150 kt = 77.16 m/s
  var MIN_VELOCITY_INTENSITY = params.minVelocity || 0.514; 
  var MAX_VELOCITY_INTENSITY = params.maxVelocity || 77.16; 
  
  var VELOCITY_SCALE =
    (params.velocityScale || 0.005) *
    (Math.pow(window.devicePixelRatio, 1 / 3) || 1); 
  var MAX_PARTICLE_AGE = params.particleAge || 90; 
  var PARTICLE_LINE_WIDTH = params.lineWidth || 1; 
  var PARTICLE_MULTIPLIER = params.particleMultiplier || 1 / 100; 
  var PARTICLE_REDUCTION = Math.pow(window.devicePixelRatio, 1 / 3) || 1.6; 
  var FRAME_RATE = params.frameRate || 15;
  var FRAME_TIME = 1000 / FRAME_RATE; 
  var OPACITY = 0.97;

  var defaulColorScale = [
    "#ffffff", // 0 kt (Calm / White background)
    "#7ac1e4", // 1-10 kt (Light blue)
    "#4ba9df", // 15 kt
    "#2c82b9", // 20 kt (Deep blue)
    "#33a02c", // 25 kt (Light green)
    "#227a1e", // 34 kt (Tropical Depression / Dark Green)
    "#b2df8a", // 40 kt (Light yellow-green)
    "#fdbf6f", // 50 kt (Yellow / Tropical Storm)
    "#ff7f00", // 64 kt (Orange / Category 1 Hurricane)
    "#e31a1c", // 80 kt (Red / Category 2)
    "#b15928", // 95 kt (Dark Red-Brown / Category 3)
    "#f768a1", // 110 kt (Magenta-Pink / Category 4)
    "#ae017e", // 130 kt (Deep Purple)
    "#49006a", // 140 kt (Dark Violet / Category 5)
    "#000000"  // 150+ kt (Black / Extreme core -> Changed from #ffffff)
  ];

  const colorScale = params.colorScale || defaulColorScale;

  var NULL_WIND_VECTOR = [NaN, NaN, null]; 

  var builder;
  var grid;
  var gridData = params.data;
  var date;
  var λ0, φ0, Δλ, Δφ, ni, nj;

  var setData = function(data) {
    gridData = data;
  };

  var setOptions = function(options) {
    if (options.hasOwnProperty("minVelocity"))
      MIN_VELOCITY_INTENSITY = options.minVelocity;

    if (options.hasOwnProperty("maxVelocity"))
      MAX_VELOCITY_INTENSITY = options.maxVelocity;

    if (options.hasOwnProperty("velocityScale"))
      VELOCITY_SCALE =
        (options.velocityScale || 0.005) *
        (Math.pow(window.devicePixelRatio, 1 / 3) || 1);

    if (options.hasOwnProperty("particleAge"))
      MAX_PARTICLE_AGE = options.particleAge;

    if (options.hasOwnProperty("lineWidth"))
      PARTICLE_LINE_WIDTH = options.lineWidth;

    if (options.hasOwnProperty("particleMultiplier"))
      PARTICLE_MULTIPLIER = options.particleMultiplier;

    if (options.hasOwnProperty("opacity")) OPACITY = +options.opacity;

    if (options.hasOwnProperty("frameRate")) FRAME_RATE = options.frameRate;
    FRAME_TIME = 1000 / FRAME_RATE;
  };

  // interpolation for vectors like wind (u,v,m)
  var bilinearInterpolateVector = function(x, y, g00, g10, g01, g11) {
    var rx = 1 - x;
    var ry = 1 - y;
    var a = rx * ry,
      b = x * ry,
      c = rx * y,
      d = x * y;
    var u = g00[0] * a + g10[0] * b + g01[0] * c + g11[0] * d;
    var v = g00[1] * a + g10[1] * b + g01[1] * c + g11[1] * d;
    return [u, v, Math.sqrt(u * u + v * v)];
  };

  var createWindBuilder = function(uComp, vComp) {
    var uData = uComp.data,
      vData = vComp.data;
    return {
      header: uComp.header,
      data: function(i) {
        return [uData[i], vData[i]];
      },
      interpolate: bilinearInterpolateVector
    };
  };

  var createBuilder = function(data) {
    var uComp = null,
      vComp = null,
      scalar = null;

    data.forEach(function(record) {
      switch (
        record.header.parameterCategory +
        "," +
        record.header.parameterNumber
      ) {
        case "1,2":
        case "2,2":
          uComp = record;
          break;
        case "1,3":
        case "2,3":
          vComp = record;
          break;
        default:
          scalar = record;
      }
    });

    return createWindBuilder(uComp, vComp);
  };

  var buildGrid = function(data, callback) {
    var supported = true;

    if (data.length < 2 ) supported = false;
    if (!supported) console.log("Windy Error: data must have at least two components (u,v)");
    
    builder = createBuilder(data);
    var header = builder.header;

    if (header.hasOwnProperty("gridDefinitionTemplate") && header.gridDefinitionTemplate != 0 ) supported = false;
    if (!supported) {
      console.log("Windy Error: Only data with Latitude_Longitude coordinates is supported");
    }
    supported = true;  
    
    λ0 = header.lo1;
    φ0 = header.la1; 

    Δλ = header.dx;
    Δφ = header.dy; 

    ni = header.nx;
    nj = header.ny; 

    if (header.hasOwnProperty("scanMode")) {
      var scanModeMask = header.scanMode.toString(2)
      scanModeMask = ('0'+scanModeMask).slice(-8);
      var scanModeMaskArray = scanModeMask.split('').map(Number).map(Boolean);

      if (scanModeMaskArray[0]) Δλ =-Δλ;
      if (scanModeMaskArray[1]) Δφ = -Δφ;
      if (scanModeMaskArray[2]) supported = false;
      if (scanModeMaskArray[3]) supported = false;
      if (scanModeMaskArray[4]) supported = false;
      if (scanModeMaskArray[5]) supported = false;
      if (scanModeMaskArray[6]) supported = false;
      if (scanModeMaskArray[7]) supported = false;
      if (!supported) console.log("Windy Error: Data with scanMode: "+header.scanMode+ " is not supported.");
    }
    date = new Date(header.refTime);
    date.setHours(date.getHours() + header.forecastTime);

    grid = [];
    var p = 0;
    var isContinuous = Math.floor(ni * Δλ) >= 360;

    for (var j = 0; j < nj; j++) {
      var row = [];
      for (var i = 0; i < ni; i++, p++) {
        row[i] = builder.data(p);
      }
      if (isContinuous) {
        row.push(row[0]);
      }
      grid[j] = row;
    }

    callback({
      date: date,
      interpolate: interpolate
    });
  };

  var interpolate = function(λ, φ) {
    if (!grid) return null;

    var i = floorMod(λ - λ0, 360) / Δλ; 
    var j = (φ0 - φ) / Δφ; 

    var fi = Math.floor(i),
      ci = fi + 1;
    var fj = Math.floor(j),
      cj = fj + 1;

    var row;
    if ((row = grid[fj])) {
      var g00 = row[fi];
      var g10 = row[ci];
      if (isValue(g00) && isValue(g10) && (row = grid[cj])) {
        var g01 = row[fi];
        var g11 = row[ci];
        if (isValue(g01) && isValue(g11)) {
          return builder.interpolate(i - fi, j - fj, g00, g10, g01, g11);
        }
      }
    }
    return null;
  };

  var isValue = function(x) {
    return x !== null && x !== undefined;
  };

  var floorMod = function(a, n) {
    return a - n * Math.floor(a / n);
  };

  var clamp = function(x, range) {
    return Math.max(range[0], Math.min(x, range[1]));
  };

  var isMobile = function() {
    return /android|blackberry|iemobile|ipad|iphone|ipod|opera mini|webos/i.test(
      navigator.userAgent
    );
  };

  var distort = function(projection, λ, φ, x, y, scale, wind) {
    var u = wind[0] * scale;
    var v = wind[1] * scale;
    var d = distortion(projection, λ, φ, x, y);

    wind[0] = d[0] * u + d[2] * v;
    wind[1] = d[1] * u + d[3] * v;
    return wind;
  };

  var distortion = function(projection, λ, φ, x, y) {
    var τ = 2 * Math.PI;
    var H = 5; 
    var hλ = λ < 0 ? H : -H;
    var hφ = φ < 0 ? H : -H;

    var pλ = project(φ, λ + hλ);
    var pφ = project(φ + hφ, λ);

    var k = Math.cos((φ / 360) * τ);
    return [
      (pλ[0] - x) / hλ / k,
      (pλ[1] - y) / hλ / k,
      (pφ[0] - x) / hφ,
      (pφ[1] - y) / hφ
    ];
  };

  var createField = function(columns, bounds, callback) {
    function field(x, y) {
      var column = columns[Math.round(x)];
      return (column && column[Math.round(y)]) || NULL_WIND_VECTOR;
    }

    field.release = function() {
      columns = [];
    };

    field.randomize = function(o) {
      var x, y;
      var safetyNet = 0;
      do {
        x = Math.round(Math.floor(Math.random() * bounds.width) + bounds.x);
        y = Math.round(Math.floor(Math.random() * bounds.height) + bounds.y);
      } while (field(x, y)[2] === null && safetyNet++ < 30);
      o.x = x;
      o.y = y;
      return o;
    };

    callback(bounds, field);
  };

  var buildBounds = function(bounds, width, height) {
    var upperLeft = bounds[0];
    var lowerRight = bounds[1];
    var x = Math.round(upperLeft[0]); 
    var y = Math.max(Math.floor(upperLeft[1], 0), 0);
    var xMax = Math.min(Math.ceil(lowerRight[0], width), width - 1);
    var yMax = Math.min(Math.ceil(lowerRight[1], height), height - 1);
    return {
      x: x,
      y: y,
      xMax: width,
      yMax: yMax,
      width: width,
      height: height
    };
  };

  var deg2rad = function(deg) {
    return (deg / 180) * Math.PI;
  };

  var invert = function(x, y, windy) {
    var latlon = params.map.containerPointToLatLng(L.point(x, y));
    return [latlon.lng, latlon.lat];
  };

  var project = function(lat, lon, windy) {
    var xy = params.map.latLngToContainerPoint(L.latLng(lat, lon));
    return [xy.x, xy.y];
  };

  var interpolateField = function(grid, bounds, extent, callback) {
    var projection = {}; 
    var mapArea = (extent.south - extent.north) * (extent.west - extent.east);
    var velocityScale = VELOCITY_SCALE * Math.pow(mapArea, 0.4);

    var columns = [];
    var x = bounds.x;

    function interpolateColumn(x) {
      var column = [];
      for (var y = bounds.y; y <= bounds.yMax; y += 2) {
        var coord = invert(x, y);
        if (coord) {
          var λ = coord[0],
            φ = coord[1];
          if (isFinite(λ)) {
            var wind = grid.interpolate(λ, φ);
            if (wind) {
              wind = distort(projection, λ, φ, x, y, velocityScale, wind);
              column[y + 1] = column[y] = wind;
            }
          }
        }
      }
      columns[x + 1] = columns[x] = column;
    }

    (function batchInterpolate() {
      var start = Date.now();
      while (x < bounds.width) {
        interpolateColumn(x);
        x += 2;
        if (Date.now() - start > 1000) {
          setTimeout(batchInterpolate, 25);
          return;
        }
      }
      createField(columns, bounds, callback);
    })();
  };

  var animationLoop;
  var animate = function(bounds, field) {
    function windIntensityColorScale(min, max) {
      colorScale.indexFor = function(m) {
        // map velocity speed linearly across the total color buckets
        return Math.max(
          0,
          Math.min(
            colorScale.length - 1,
            Math.round(((m - min) / (max - min)) * (colorScale.length - 1))
          )
        );
      };

      return colorScale;
    }

    var colorStyles = windIntensityColorScale(
      MIN_VELOCITY_INTENSITY,
      MAX_VELOCITY_INTENSITY
    );
    var buckets = colorStyles.map(function() {
      return [];
    });

    var particleCount = Math.round(
      bounds.width * bounds.height * PARTICLE_MULTIPLIER
    );
    if (isMobile()) {
      particleCount *= PARTICLE_REDUCTION;
    }

    var fadeFillStyle = `rgba(0, 0, 0, ${OPACITY})`;

    var particles = [];
    for (var i = 0; i < particleCount; i++) {
      particles.push(
        field.randomize({
          age: Math.floor(Math.random() * MAX_PARTICLE_AGE) + 0
        })
      );
    }

    function evolve() {
      buckets.forEach(function(bucket) {
        bucket.length = 0;
      });
      particles.forEach(function(particle) {
        if (particle.age > MAX_PARTICLE_AGE) {
          field.randomize(particle).age = 0;
        }
        var x = particle.x;
        var y = particle.y;
        var v = field(x, y); 
        var m = v[2];
        if (m === null) {
          particle.age = MAX_PARTICLE_AGE; 
        } else {
          var xt = x + v[0];
          var yt = y + v[1];
          if (field(xt, yt)[2] !== null) {
            particle.xt = xt;
            particle.yt = yt;
            buckets[colorStyles.indexFor(m)].push(particle);
          } else {
            particle.x = xt;
            particle.y = yt;
          }
        }
        particle.age += 1;
      });
    }

    var g = params.canvas.getContext("2d");
    g.lineWidth = PARTICLE_LINE_WIDTH;
    g.fillStyle = fadeFillStyle;
    g.globalAlpha = 0.6;

    function draw() {
      var prev = "lighter";
      g.globalCompositeOperation = "destination-in";
      g.fillRect(bounds.x, bounds.y, bounds.width, bounds.height);
      g.globalCompositeOperation = prev;
      g.globalAlpha = OPACITY === 0 ? 0 : OPACITY * 0.9;

      buckets.forEach(function(bucket, i) {
        if (bucket.length > 0) {
          g.beginPath();
          g.strokeStyle = colorStyles[i];
          bucket.forEach(function(particle) {
            g.moveTo(particle.x, particle.y);
            g.lineTo(particle.xt, particle.yt);
            particle.x = particle.xt;
            particle.y = particle.yt;
          });
          g.stroke();
        }
      });
    }

    var then = Date.now();
    (function frame() {
      animationLoop = requestAnimationFrame(frame);
      var now = Date.now();
      var delta = now - then;
      if (delta > FRAME_TIME) {
        then = now - (delta % FRAME_TIME);
        evolve();
        draw();
      }
    })();
  };

  var start = function(bounds, width, height, extent) {
    var mapBounds = {
      south: deg2rad(extent[0][1]),
      north: deg2rad(extent[1][1]),
      east: deg2rad(extent[1][0]),
      west: deg2rad(extent[0][0]),
      width: width,
      height: height
    };

    stop();

    buildGrid(gridData, function(grid) {
      interpolateField(
        grid,
        buildBounds(bounds, width, height),
        mapBounds,
        function(bounds, field) {
          windy.field = field;
          animate(bounds, field);
        }
      );
    });
  };

  var stop = function() {
    if (windy.field) windy.field.release();
    if (animationLoop) cancelAnimationFrame(animationLoop);
  };

  var windy = {
    params: params,
    start: start,
    stop: stop,
    createField: createField,
    interpolatePoint: interpolate,
    setData: setData,
    setOptions: setOptions
  };

  return windy;
};

if (!window.cancelAnimationFrame) {
  window.cancelAnimationFrame = function(id) {
    clearTimeout(id);
  };
}