// Hive static replay shell: fetches the replay named by ?replay=<url>, hands
// the bytes to the wasm module (which re-derives every frame with the same
// integer Nim sim the game server runs), and drives the broadcast chrome in
// replay_broadcast.html.
//
// Forked from paintbot's `replay-viewer/static_replay.js`: the same
// `data-replay-loaded` / `data-replay-mismatch-tick` attributes, the same
// showFailure surface, the same stage-note read after an ABORTING_MALLOC
// abort. Two changes, both deliberate: the loader hands the JSON replay to
// the wasm module instead of the binary one, and bullwhip's `coworld-replay`
// postMessage bridge is added verbatim.
(function () {
  "use strict";

  var FETCH_TIMEOUT_MS = 20000;

  // VIEWER -> HOST READINESS. An embedding page (the softmax.com theater, the
  // Observatory episode page) can only see this document's `load` event,
  // which fires long before the wasm module has compiled and the replay has
  // come back from S3. So the shell tells the parent what it is doing:
  // `loading` as soon as this script runs (before `load`, so the host never
  // mistakes document-load for a picture), `ready` once the renderer has
  // drawn its first frame, `error` when the replay cannot be shown. No
  // secrets ride on it, so the target origin is "*".
  function tell(type, message) {
    if (window.parent === window) return;
    var envelope = { src: "coworld-replay", type: type };
    if (message) envelope.message = message;
    try { window.parent.postMessage(envelope, "*"); } catch (ignore) {}
  }
  tell("loading");

  var modulePromise = null;
  var attempt = 0;

  function caption(text) {
    var cap = document.getElementById("lk-cap");
    if (cap) cap.textContent = text;
    var status = document.getElementById("status");
    if (status) { status.textContent = text; status.classList.add("show"); }
  }

  function fail(message) {
    document.documentElement.setAttribute("data-replay-error", message);
    var status = document.getElementById("status");
    if (status) {
      status.textContent = "Replay failed: " + message + " ";
      status.classList.add("show");
      if (!document.getElementById("loading-retry")) {
        var retry = document.createElement("button");
        retry.id = "loading-retry";
        retry.type = "button";
        retry.textContent = "Retry";
        retry.onclick = function () { retry.remove(); load(); };
        status.appendChild(retry);
      }
    }
    if (window.HiveChrome && window.HiveChrome.fail) {
      window.HiveChrome.fail(new Error(message));
    }
    tell("error", message);
  }

  function readString(module, ptr, len) {
    if (!ptr || !len) return "";
    return new TextDecoder().decode(module.HEAPU8.subarray(ptr, ptr + len));
  }

  function stageNote(module) {
    try {
      var len = module._hive_stage_len ? module._hive_stage_len() : 0;
      if (!len) return "";
      return readString(module, module._hive_stage_ptr(), len);
    } catch (ignore) { return ""; }
  }

  function fetchReplay(url) {
    // AbortController bounds the wait: a fetch that never answers (a dead CDN
    // edge, a proxy holding the socket) is otherwise indistinguishable from a
    // slow one and the curtain would say LOADING until the tab died.
    var controller = typeof AbortController === "function" ?
      new AbortController() : null;
    var timer = window.setTimeout(function () {
      if (controller) controller.abort();
    }, FETCH_TIMEOUT_MS);
    return fetch(url, controller ? { signal: controller.signal } : {})
      .then(function (response) {
        if (!response.ok) throw new Error("replay fetch " + response.status);
        return response.arrayBuffer();
      })
      .catch(function (error) {
        if (error && error.name === "AbortError") {
          throw new Error("replay fetch timed out after " +
            Math.round(FETCH_TIMEOUT_MS / 1000) + "s");
        }
        throw error;
      })
      .finally(function () { window.clearTimeout(timer); });
  }

  function makeApi(module) {
    function pass(text) {
      var bytes = new TextEncoder().encode(text);
      var ptr = module._malloc(bytes.length);
      module.HEAPU8.set(bytes, ptr);
      try { module._hive_input(ptr, bytes.length); }
      finally { module._free(ptr); }
    }
    return {
      input: pass,
      frame: function () { return module._hive_frame() > 0; },
      packet: function () {
        var len = module._hive_packet_len();
        if (!len) return null;
        var ptr = module._hive_packet_ptr();
        return module.HEAPU8.subarray(ptr, ptr + len);
      },
      rock: function () {
        var len = module._hive_rock_len();
        if (!len) return null;
        var ptr = module._hive_rock_ptr();
        return module.HEAPU8.slice(ptr, ptr + len);
      },
      tick: function () { return module._hive_tick(); },
      mismatchTick: function () { return module._hive_mismatch_tick(); },
      error: function () {
        var text = readString(module, module._hive_error_ptr(),
          module._hive_error_len());
        return text || stageNote(module);
      }
    };
  }

  function start(module, bytes) {
    var ptr = module._malloc(bytes.length);
    module.HEAPU8.set(bytes, ptr);
    var ok = module._hive_load_replay(ptr, bytes.length);
    module._free(ptr);
    if (!ok) {
      fail(readString(module, module._hive_error_ptr(),
        module._hive_error_len()) || stageNote(module) ||
        "wasm rejected the replay");
      return;
    }
    var api = makeApi(module);
    var replay = JSON.parse(new TextDecoder().decode(bytes));
    document.documentElement.removeAttribute("data-replay-error");
    var status = document.getElementById("status");
    if (status) { status.textContent = ""; status.classList.remove("show"); }
    Promise.resolve(window.HiveChrome.attach({
      replay: replay,
      api: api,
      rock: api.rock(),
      assetBase: "./art"
    })).then(function () {
      // Report ready one frame after the first drawn frame, so "ready" means
      // a picture and not merely a parsed payload.
      window.requestAnimationFrame(function () {
        window.requestAnimationFrame(function () { tell("ready"); });
      });
    }).catch(function (error) {
      fail(String((error && error.message) || error));
    });
  }

  function load() {
    var replayUrl = new URLSearchParams(location.search).get("replay");
    if (!replayUrl) {
      fail("missing required ?replay= URL");
      return;
    }
    attempt += 1;
    document.documentElement.removeAttribute("data-replay-error");
    caption(attempt > 1 ? "RETRYING REPLAY… (attempt " + attempt + ")" :
      "LOADING REPLAY…");
    if (!modulePromise) {
      modulePromise = HiveReplayModule().catch(function (error) {
        modulePromise = null;   // a failed compile is retried from scratch
        throw error;
      });
    }
    Promise.all([fetchReplay(replayUrl), modulePromise])
      .then(function (results) {
        start(results[1], new Uint8Array(results[0]));
      })
      .catch(function (error) {
        fail(String((error && error.message) || error));
      });
  }

  window.addEventListener("load", load);
})();
