#!/usr/bin/env node
// Node smoke for the EXACT emitted wasm module. Forked from paintbot's
// tools/wasm_replay_smoke.cjs.
//
// wasm32-only failures — integer overflow traps, 2 GB address-space
// exhaustion, a use-after-free in the Nim epilogue — are invisible to the
// native 64-bit tests, so CI runs the module the browser will run.
//
//   usage: node tools/wasm_replay_smoke.cjs <dist-dir> <replay.json>
'use strict';

const fs = require('fs');
const path = require('path');

const distDir = path.resolve(process.argv[2] ||
  path.join(__dirname, '..', 'replay-viewer', 'dist'));
const replayPath = path.resolve(process.argv[3] ||
  path.join(__dirname, '..', 'tests', 'fixtures', 'sample_replay.json'));

function fail(message) {
  console.error('FAIL: ' + message);
  process.exit(1);
}

function readString(module, ptr, len) {
  if (!ptr || !len) return '';
  return Buffer.from(module.HEAPU8.subarray(ptr, ptr + len)).toString('utf8');
}

function api(module) {
  function input(text) {
    const bytes = Buffer.from(text, 'utf8');
    const ptr = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, ptr);
    try { module._hive_input(ptr, bytes.length); } finally { module._free(ptr); }
  }
  return {
    input,
    frame: () => module._hive_frame(),
    tick: () => module._hive_tick(),
    mismatch: () => module._hive_mismatch_tick(),
    packet: () => {
      const len = module._hive_packet_len();
      if (!len) return null;
      const ptr = module._hive_packet_ptr();
      return Buffer.from(module.HEAPU8.subarray(ptr, ptr + len));
    },
    rockLen: () => module._hive_rock_len(),
    error: () => readString(module, module._hive_error_ptr(),
      module._hive_error_len()),
    stage: () => readString(module, module._hive_stage_ptr(),
      module._hive_stage_len()),
  };
}

function loadReplay(module, bytes) {
  const ptr = module._malloc(bytes.length);
  module.HEAPU8.set(bytes, ptr);
  const ok = module._hive_load_replay(ptr, bytes.length);
  module._free(ptr);
  return ok;
}

// A five-line DOM stub is enough to load the page's decoder in node: the
// decode path touches no canvas, and everything that does is only reached
// from draw().
function decodeWithPage(packet) {
  const stubCanvas = { getContext: () => ({}), width: 0, height: 0 };
  global.window = global;
  global.document = { createElement: () => stubCanvas };
  global.Image = function () {};
  require(path.join(__dirname, '..', 'client', 'broadcast_core.js'));
  const board = Object.create(global.window.HiveBoard.prototype);
  return board.decode(new Uint8Array(packet));
}

async function main() {
  const modulePath = path.join(distDir, 'hive_replay.js');
  if (!fs.existsSync(modulePath)) fail('no wasm module at ' + modulePath);
  // The emitted loader resolves its .data package relative to the process
  // working directory under node, so run from the bundle.
  process.chdir(distDir);
  const factory = require(modulePath);
  const module = await factory();
  const a = api(module);

  const raw = fs.readFileSync(replayPath);
  const replay = JSON.parse(raw.toString('utf8'));

  if (!loadReplay(module, raw)) fail('the module rejected a good replay: ' + a.error());
  if (a.rockLen() !== replay.field.cols * replay.field.rows) {
    fail('the rock mask is the wrong size: ' + a.rockLen());
  }

  // Advance to the end one tick at a time and check the tick total.
  let frames = 0;
  while (a.tick() < replay.tick_count) {
    if (a.frame() <= 0) fail('hive_frame failed at tick ' + a.tick() + ': ' + a.error());
    frames += 1;
    if (frames > replay.tick_count + 10) fail('hive_frame never reached the end');
  }
  if (a.tick() !== replay.tick_count) {
    fail('final tick ' + a.tick() + ' != tick_count ' + replay.tick_count);
  }
  if (a.mismatch() !== -1) {
    fail('digest mismatch at tick ' + a.mismatch() +
      ' — the wasm build does not reproduce the native sim');
  }

  const packet = a.packet();
  if (!packet || packet.length < 52) fail('empty frame packet');
  if (packet.toString('ascii', 0, 4) !== 'HVP1') fail('bad packet magic');
  const expected = 52 + 96 * 4 +
    4 * 2 * replay.field.cols * replay.field.rows;
  if (packet.length < expected) {
    fail('packet is ' + packet.length + ' bytes, expected at least ' + expected);
  }
  const finalDelivered = packet.readUInt32LE(24);
  if (finalDelivered !== replay.results.delivered[0]) {
    fail('packet delivered[0] ' + finalDelivered + ' != results ' +
      replay.results.delivered[0]);
  }

  // Cross-check the packet against the page's own decoder, so the Nim writer
  // in src/hive/render.nim and the JS reader in client/broadcast_core.js can
  // never drift apart unnoticed.
  const decoded = decodeWithPage(packet);
  if (decoded === null) fail('client/broadcast_core.js rejected a real packet');
  if (decoded.cols !== replay.field.cols || decoded.rows !== replay.field.rows) {
    fail('decoded field size ' + decoded.cols + 'x' + decoded.rows);
  }
  if (decoded.antCount !== 96) fail('decoded ' + decoded.antCount + ' ants');
  if (decoded.ants.length !== 96 * 4) fail('ant block is the wrong length');
  if (decoded.planes.length !== 4) fail('four colonies of planes');
  for (const pair of decoded.planes) {
    if (pair.length !== 2) fail('two planes a colony');
    for (const plane of pair) {
      if (plane.length !== decoded.cols * decoded.rows) {
        fail('a plane is the wrong length');
      }
    }
  }
  if (decoded.tick !== replay.tick_count) {
    fail('decoded tick ' + decoded.tick + ' != ' + replay.tick_count);
  }
  for (let seat = 0; seat < 4; seat++) {
    if (decoded.delivered[seat] !== replay.results.delivered[seat]) {
      fail('decoded delivered[' + seat + '] disagrees with the results');
    }
  }
  for (let cx = 0; cx < decoded.cols; cx++) {
    for (let cy = 0; cy < decoded.rows; cy++) {
      // the mirror invariant, read straight off the wire
      if (decoded.planes[0][0][cy * decoded.cols + cx] > 255) {
        fail('a pheromone byte is out of range');
      }
    }
  }

  // Seeks: mid, backwards and to the end must all land exactly.
  for (const target of [Math.floor(replay.tick_count / 2), 96, 0,
                        replay.tick_count]) {
    a.input(JSON.stringify({ seek: target }));
    if (a.frame() <= 0) fail('seek to ' + target + ' failed: ' + a.error());
    if (a.tick() !== target) {
      fail('seek to ' + target + ' landed on ' + a.tick());
    }
  }
  if (a.mismatch() !== -1) fail('seeking tripped the digest check');

  // Malformed inputs must be REJECTED with a message, not crash the runtime.
  const bad = [
    ['bad protocol', raw.toString('utf8').replace('hive.replay.v1', 'nope.v1')],
    ['truncated json', raw.toString('utf8').slice(0, raw.length / 2)],
    ['bad base64 length', raw.toString('utf8').replace('"ants_b64":"', '"ants_b64":"AAAA')],
    ['tick_count mismatch', raw.toString('utf8').replace(
      '"tick_count":' + replay.tick_count, '"tick_count":' + (replay.tick_count + 240))],
    ['out-of-range doctrine', raw.toString('utf8').replace('"scouts":55', '"scouts":5500')],
  ];
  for (const [label, text] of bad) {
    const ok = loadReplay(module, Buffer.from(text, 'utf8'));
    if (ok) fail('the module accepted a malformed replay: ' + label);
    if (!a.error()) fail('no diagnostic for: ' + label);
  }

  // …and a good replay still loads afterwards, so a rejection does not
  // poison the runtime.
  if (!loadReplay(module, raw)) fail('a good replay failed after a rejection');

  console.log('wasm replay smoke OK: ' + replay.tick_count + ' ticks, ' +
    frames + ' frames, packet ' + packet.length + 'B, no digest mismatch');
}

main().catch((error) => fail(error && error.stack || String(error)));
