'use strict';
// broadcast_core.js — the hive board renderer.
//
// Paintbot's split, kept: the wasm module re-derives the whole match from the
// doctrine stream and emits one compact binary packet per frame
// (src/hive/render.nim documents the layout byte for byte); this file decodes
// that packet and composites the painted art — the meadow floor, the rock,
// the four nest mounds, the food caches, the ants — plus the two additive
// pheromone layers that are the headline readout. The DOM chrome
// (replay_broadcast.html) owns the scorebug, the nest counters, the doctrine
// chips, the feed, the transport and the warnings.
//
// Everything drawn here is derived from the packet. Nothing is fetched.

(function () {
  var CELL = 8;
  var ANT_PX = 30;   // ant sprite side in world px (3.75 cells)

  function hexToRgb(hex) {
    var h = String(hex || '#ffffff').replace('#', '');
    if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
    var n = parseInt(h, 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }

  function loadImage(src) {
    return new Promise(function (resolve) {
      var img = new Image();
      img.onload = function () { resolve(img); };
      // A missing asset must never wedge playback: resolve with null and the
      // renderer falls back to a painted primitive for that layer only.
      img.onerror = function () { resolve(null); };
      img.src = src;
    });
  }

  function HiveBoard(canvas, assetBase) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.assetBase = assetBase || './art';
    this.cols = 160;
    this.rows = 88;
    this.rock = null;
    this.colours = ['#f2c14e', '#4ecdc4', '#9fd356', '#e26db5'];
    this.art = {};
    this._antTints = {};
    this.rockLayer = null;
    this.glow = document.createElement('canvas');
    this.glowCtx = this.glow.getContext('2d');
    this.frame = null;
    this.rings = [];
    this.zoom = 1;
    this.focusX = 0.5;
    this.focusY = 0.5;
  }

  HiveBoard.prototype.loadArt = function () {
    var self = this;
    var names = ['meadow_floor.jpg', 'rock.png', 'nest_amber.png',
      'nest_teal.png', 'nest_lime.png', 'nest_magenta.png', 'food_cache.png',
      'ant.png', 'ant_laden.png'];
    return Promise.all(names.map(function (n) {
      return loadImage(self.assetBase + '/' + n);
    })).then(function (images) {
      names.forEach(function (n, i) { self.art[n] = images[i]; });
      return self;
    });
  };

  HiveBoard.prototype.setField = function (cols, rows, rockBytes, colours) {
    this.cols = cols;
    this.rows = rows;
    this.rock = rockBytes;
    if (colours && colours.length === 4) this.colours = colours.slice();
    this._antTints = {};
    this.glow.width = cols;
    this.glow.height = rows;
    this.canvas.width = cols * CELL;
    this.canvas.height = rows * CELL;
    this.buildRockLayer();
  };

  // The rock layer never changes, so it is stamped once into an offscreen
  // canvas: the painted lichen tile clipped to the baked mask, with a darker
  // rim on every cell that borders open floor.
  HiveBoard.prototype.buildRockLayer = function () {
    var w = this.cols * CELL, h = this.rows * CELL;
    var layer = document.createElement('canvas');
    layer.width = w;
    layer.height = h;
    var c = layer.getContext('2d');
    var tile = this.art['rock.png'];
    if (tile) {
      var pattern = c.createPattern(tile, 'repeat');
      c.fillStyle = pattern;
    } else {
      c.fillStyle = '#4a4640';
    }
    c.fillRect(0, 0, w, h);
    // Knock out everything that is not rock.
    c.globalCompositeOperation = 'destination-in';
    c.fillStyle = '#fff';
    for (var cy = 0; cy < this.rows; cy++) {
      for (var cx = 0; cx < this.cols; cx++) {
        if (this.rock && this.rock[cy * this.cols + cx]) {
          c.fillRect(cx * CELL, cy * CELL, CELL, CELL);
        }
      }
    }
    c.globalCompositeOperation = 'source-over';
    c.strokeStyle = 'rgba(16, 12, 9, 0.55)';
    c.lineWidth = 1;
    for (cy = 0; cy < this.rows; cy++) {
      for (cx = 0; cx < this.cols; cx++) {
        if (!this.rock || !this.rock[cy * this.cols + cx]) continue;
        var open = (cy === 0 || !this.rock[(cy - 1) * this.cols + cx]) ||
          (cy === this.rows - 1 || !this.rock[(cy + 1) * this.cols + cx]) ||
          (cx === 0 || !this.rock[cy * this.cols + cx - 1]) ||
          (cx === this.cols - 1 || !this.rock[cy * this.cols + cx + 1]);
        if (open) c.strokeRect(cx * CELL + 0.5, cy * CELL + 0.5, CELL - 1, CELL - 1);
      }
    }
    this.rockLayer = layer;
  };

  // ---- packet decode -------------------------------------------------------
  HiveBoard.prototype.decode = function (bytes) {
    if (!bytes || bytes.length < 52) return null;
    if (bytes[0] !== 72 || bytes[1] !== 86 || bytes[2] !== 80 ||
        bytes[3] !== 49) {
      return null;               // not "HVP1"
    }
    var view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    var f = {
      tick: view.getUint32(4, true),
      turn: view.getUint32(8, true),
      cols: view.getUint16(12, true),
      rows: view.getUint16(14, true),
      antCount: view.getUint16(16, true),
      sourceCount: view.getUint16(18, true),
      digest: view.getUint32(20, true),
      delivered: [],
      carrying: [],
      seatNest: [],
      ants: null,
      sources: [],
      planes: null
    };
    var o = 24;
    for (var i = 0; i < 4; i++) { f.delivered.push(view.getUint32(o, true)); o += 4; }
    for (i = 0; i < 4; i++) { f.carrying.push(view.getUint16(o, true)); o += 2; }
    for (i = 0; i < 4; i++) { f.seatNest.push(bytes[o]); o += 1; }
    f.ants = bytes.subarray(o, o + f.antCount * 4);
    o += f.antCount * 4;
    for (i = 0; i < f.sourceCount; i++) {
      f.sources.push({
        id: view.getUint16(o, true),
        cx: bytes[o + 2],
        cy: bytes[o + 3],
        amount: view.getUint16(o + 4, true),
        spawnAmount: view.getUint16(o + 6, true)
      });
      o += 8;
    }
    var planeBytes = f.cols * f.rows;
    f.planes = [];
    for (var colony = 0; colony < 4; colony++) {
      f.planes.push([
        bytes.subarray(o, o + planeBytes),
        bytes.subarray(o + planeBytes, o + 2 * planeBytes)
      ]);
      o += 2 * planeBytes;
    }
    return f;
  };

  // ---- pheromone glow ------------------------------------------------------
  // Two additive layers per colony over the floor: the FOOD trail in the
  // colony's hue at alpha = min(0.55, F/255 * 0.55), and the HOME trail in the
  // same hue desaturated and darkened at alpha = min(0.22, H/255 * 0.22),
  // drawn UNDER the food layer. Composited at cell resolution and scaled up
  // with smoothing, which is what gives the 1-cell bloom.
  HiveBoard.prototype.paintGlow = function (f) {
    var w = f.cols, h = f.rows, n = w * h;
    var image = this.glowCtx.createImageData(w, h);
    var data = image.data;
    var hues = [];
    var dim = [];
    for (var c = 0; c < 4; c++) {
      var rgb = hexToRgb(this.colours[c]);
      hues.push(rgb);
      var grey = (rgb[0] + rgb[1] + rgb[2]) / 3;
      dim.push([
        Math.round((rgb[0] * 0.4 + grey * 0.6) * 0.55),
        Math.round((rgb[1] * 0.4 + grey * 0.6) * 0.55),
        Math.round((rgb[2] * 0.4 + grey * 0.6) * 0.55)
      ]);
    }
    for (var i = 0; i < n; i++) {
      var r = 0, g = 0, b = 0, a = 0;
      for (c = 0; c < 4; c++) {
        var home = f.planes[c][1][i];
        if (home) {
          var ah = Math.min(0.22, (home / 255) * 0.22);
          r += dim[c][0] * ah; g += dim[c][1] * ah; b += dim[c][2] * ah; a += ah;
        }
        var food = f.planes[c][0][i];
        if (food) {
          var af = Math.min(0.55, (food / 255) * 0.55);
          r += hues[c][0] * af; g += hues[c][1] * af; b += hues[c][2] * af; a += af;
        }
      }
      if (a <= 0) continue;
      var p = i * 4;
      data[p] = Math.min(255, r / a);
      data[p + 1] = Math.min(255, g / a);
      data[p + 2] = Math.min(255, b / a);
      data[p + 3] = Math.min(235, Math.round(a * 255));
    }
    this.glowCtx.putImageData(image, 0, 0);
  };

  // The ant sheet is rendered in neutral off-white plating so one sprite
  // serves every nest: the colony hue is composited onto the opaque pixels
  // once per (variant, colour) and cached. null colour = the untinted base.
  HiveBoard.prototype.antSprite = function (name, colour) {
    var base = this.art[name];
    if (!base) return null;
    if (!colour) return base;
    var key = name + '|' + colour;
    var hit = this._antTints[key];
    if (hit) return hit;
    var c = document.createElement('canvas');
    c.width = base.width;
    c.height = base.height;
    var g = c.getContext('2d');
    g.drawImage(base, 0, 0);
    // Blend the plating toward the colony hue; the golden crumb (the one
    // saturated-yellow region of the sheet) is left alone so a laden ant
    // still reads as "carrying food" rather than "carrying a blob".
    var rgb = hexToRgb(colour);
    var img = g.getImageData(0, 0, c.width, c.height);
    var d = img.data;
    var k = 0.55;
    for (var p = 0; p < d.length; p += 4) {
      if (!d[p + 3]) continue;
      var r = d[p], gg = d[p + 1], b = d[p + 2];
      if (r > 150 && gg > 120 && b < 140 && r > b + 60) continue;
      d[p] = r + (rgb[0] - r) * k;
      d[p + 1] = gg + (rgb[1] - gg) * k;
      d[p + 2] = b + (rgb[2] - b) * k;
    }
    g.putImageData(img, 0, 0);
    this._antTints[key] = c;
    return c;
  };

  HiveBoard.prototype.ring = function (cx, cy, colour, frames, radius) {
    this.rings.push({ cx: cx, cy: cy, colour: colour, life: frames,
      max: frames, radius: radius || 18 });
  };

  HiveBoard.prototype.draw = function (nests) {
    var f = this.frame;
    var ctx = this.ctx;
    var w = this.canvas.width, h = this.canvas.height;
    ctx.imageSmoothingEnabled = false;
    // 1. floor
    var floor = this.art['meadow_floor.jpg'];
    if (floor) {
      if (!this._floorPattern) this._floorPattern = ctx.createPattern(floor, 'repeat');
      ctx.fillStyle = this._floorPattern;
    } else {
      ctx.fillStyle = '#2c3a26';
    }
    ctx.fillRect(0, 0, w, h);
    if (!f) return;

    // 2. pheromone glow, under everything solid
    this.paintGlow(f);
    ctx.imageSmoothingEnabled = true;
    ctx.drawImage(this.glow, 0, 0, w, h);
    ctx.imageSmoothingEnabled = false;

    // 3. rock
    if (this.rockLayer) ctx.drawImage(this.rockLayer, 0, 0);

    // 4. nests
    var sprites = ['nest_amber.png', 'nest_teal.png', 'nest_lime.png',
      'nest_magenta.png'];
    for (var i = 0; i < 4 && nests && i < nests.length; i++) {
      var nx = nests[i][0] * CELL, ny = nests[i][1] * CELL;
      var sprite = this.art[sprites[i]];
      var size = CELL * 7;
      if (sprite) {
        ctx.drawImage(sprite, nx - size / 2 + CELL / 2, ny - size / 2 + CELL / 2,
          size, size);
      } else {
        ctx.fillStyle = this.colours[i];
        ctx.fillRect(nx - CELL * 2, ny - CELL * 2, CELL * 5, CELL * 5);
      }
    }

    // 5. caches, scaled by how much is left
    var cache = this.art['food_cache.png'];
    for (i = 0; i < f.sources.length; i++) {
      var s = f.sources[i];
      var fill = s.spawnAmount > 0 ? s.amount / s.spawnAmount : 1;
      var side = CELL * (2.0 + 2.4 * Math.max(0.15, fill));
      var px = s.cx * CELL + CELL / 2, py = s.cy * CELL + CELL / 2;
      if (cache) {
        ctx.drawImage(cache, px - side / 2, py - side / 2, side, side);
      } else {
        ctx.fillStyle = '#e8d07a';
        ctx.beginPath();
        ctx.arc(px, py, side / 2, 0, Math.PI * 2);
        ctx.fill();
      }
    }

    // 6. ants. Nano-banana cog-ant sprites (scripts/art/split_ant_sheet.py)
    //    drawn at ANT_PX world units, anchored at the feet, tinted to the
    //    colony hue through a per-colony cached copy. A laden ant is the
    //    variant hoisting the big golden crumb, drawn a little larger so the
    //    crumb reads at board scale; a scout keeps the neutral off-white
    //    plating (the old white pip); a held ant is ghosted.
    var ants = f.ants;
    ctx.imageSmoothingEnabled = true;
    for (i = 0; i < f.antCount; i++) {
      var ax = ants[i * 4] * CELL + CELL / 2;
      var ay = ants[i * 4 + 1] * CELL + CELL / 2;
      var st = ants[i * 4 + 2];
      var colony = ants[i * 4 + 3];
      var col = this.colours[colony] || '#fff';
      var laden = st === 2;
      var sprite = this.antSprite(laden ? 'ant_laden.png' : 'ant.png',
        st === 1 ? null : col);
      if (sprite) {
        var side = laden ? ANT_PX * 1.3 : ANT_PX;
        if (st === 3) ctx.globalAlpha = 0.45;
        ctx.drawImage(sprite, ax - side / 2, ay + ANT_PX * 0.35 - side,
          side, side);
        ctx.globalAlpha = 1;
      } else if (laden) {
        ctx.fillStyle = col;
        ctx.fillRect(ax - 2, ay - 2, 4, 4);
        ctx.fillStyle = '#fdf6e3';
        ctx.fillRect(ax - 1, ay - 1, 2, 2);
      } else if (st === 3) {
        ctx.fillStyle = 'rgba(242,232,216,0.55)';
        ctx.fillRect(ax - 1, ay - 1, 2, 2);
      } else {
        ctx.fillStyle = st === 1 ? '#fdf6e3' : col;
        ctx.fillRect(ax - 1.5, ay - 1.5, 3, 3);
      }
    }
    ctx.imageSmoothingEnabled = false;

    // 7. transient rings (deliveries, spawns, retirements)
    for (i = this.rings.length - 1; i >= 0; i--) {
      var r = this.rings[i];
      var k = 1 - r.life / r.max;
      ctx.strokeStyle = r.colour;
      ctx.globalAlpha = Math.max(0, r.life / r.max);
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.arc(r.cx * CELL + CELL / 2, r.cy * CELL + CELL / 2,
        4 + k * r.radius, 0, Math.PI * 2);
      ctx.stroke();
      ctx.globalAlpha = 1;
      r.life -= 1;
      if (r.life <= 0) this.rings.splice(i, 1);
    }
  };

  HiveBoard.prototype.ingest = function (bytes, nests) {
    var decoded = this.decode(bytes);
    if (decoded) this.frame = decoded;
    this.draw(nests);
    return this.frame;
  };

  window.HiveBoard = HiveBoard;
  window.HiveBoardUtil = { hexToRgb: hexToRgb, loadImage: loadImage, CELL: CELL };
})();
