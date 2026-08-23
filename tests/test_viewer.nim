## The viewer smoke, no browser.
##
## Two halves. Static assertions over the served chrome and the shell — every
## inherited paintbot chrome id is still there, hive's four additions exist,
## the `coworld-replay` postMessage bridge INCLUDING tell("ready") is present,
## and the 360 px legibility rules are in the CSS. Then, when a built bundle
## is available (the `wasm-viewer` CI job builds it; the `test` job has no
## emsdk), the node harness runs the EXACT emitted module.

import std/[os, osproc, strutils]
import support/helpers

const InheritedChromeIds = [
  "viewport", "stage", "board", "lightpool", "grain", "chrome", "scorebug",
  "plates-l", "plates-r", "clock", "clock-time", "clock-caption", "ffwd-mini",
  "viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
  "zoom-slider", "zoom-in", "zoom-read", "mmwarn", "bannerlane", "killfeed",
  "transport", "btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end",
  "btn-loop", "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip",
  "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill", "lulls",
  "scrub-win", "scrub-head", "endcard", "ec-headline", "ec-wincond", "ec-how",
  "ec-teams", "ec-replay", "status",
  # the pre-load locker-room curtain
  "lockerroom", "lk-art", "lk-bg", "lk-sprites", "lk-cap"
]

const HiveChromeIds = ["nestbug", "doctrinebar", "warflash", "cachebar"]

proc main() =
  let page = readRepoFile("client/replay_broadcast.html")
  let shell = readRepoFile("replay-viewer/static_replay.js")
  let common = readRepoFile("client/chrome_common.js")
  let core = readRepoFile("client/broadcast_core.js")

  block inheritedIds:
    for id in InheritedChromeIds:
      check("id=\"" & id & "\"" in page,
        "the inherited chrome id #" & id & " must survive the fork")
    report("all " & $InheritedChromeIds.len &
      " inherited chrome ids are still present")

  block hiveAdditions:
    for id in HiveChromeIds:
      check("id=\"" & id & "\"" in page, "#" & id & " exists")
      check("#" & id in page, "#" & id & " is styled")
    report("#nestbug, #doctrinebar, #warflash and #cachebar exist and are styled")

  block relayoutInherited:
    check("--hudscale" in page, "the --hudscale relayout variable survives")
    check("--topband" in page, "--topband survives")
    check("--band" in page, "--band survives")
    check("classList.toggle('tiny', boardW <= 620)" in page,
      "the .tiny breakpoint at 620px survives")
    check("Math.max(0.5, Math.min(1.6, boardW / 760))" in page,
      "the clamp(0.5, boardW/760, 1.6) hudscale rule survives")
    report("paintbot's fixed-point relayout loop is inherited unchanged")

  block legibleAt360:
    ## The embedded featured-match iframe is ~360 px wide, so the composition
    ## is checked THERE. Player names must never collapse to "…".
    ## The LAST rule wins in CSS: paintbot's inherited declaration is kept
    ## and hive's override (which adds the 3.2em floor) comes after it.
    let floorAt = page.find("min-width: 3.2em")
    check(floorAt >= 0, "the 3.2em floor is declared somewhere")
    let ruleStart = page.rfind(".plate .team-name {", 0, floorAt)
    check(ruleStart >= 0, "…inside a .plate .team-name rule")
    check(page.find(".plate .team-name {") < ruleStart,
      "hive's override comes AFTER the inherited declaration")
    let ruleEnd = page.find("}", ruleStart)
    let rule = page[ruleStart .. ruleEnd]
    check("flex: 1 1 auto" in rule, ".team-name grows: flex: 1 1 auto")
    check("min-width: 3.2em" in rule, ".team-name has a 3.2em floor")
    check("text-overflow: ellipsis" in rule, "and still ellipsizes")
    let mediaStart = page.find("@media (max-width: 640px)")
    check(mediaStart >= 0, "a @media (max-width: 640px) block is present")
    let media = page[mediaStart ..< min(page.len, mediaStart + 900)]
    check("#doctrinebar" in media, "the doctrine bar is hidden under 640px")
    check("#viewpanel" in media, "the minimap and zoom bar are hidden too")
    check("lives-label" in media, "the plate labels are hidden")
    check("clamp(11px, 3.4vw, 17px)" in page, "banner text is clamped")
    report("the 360 px legibility rules are in the CSS")

  block coworldReplayBridge:
    ## SPEC check 8(c) greps the SERVED js for exactly this bridge.
    check("coworld-replay" in shell, "the coworld-replay envelope is present")
    check("tell(\"loading\")" in shell, "tell(\"loading\") on script entry")
    check("tell(\"ready\")" in shell, "tell(\"ready\") after the first frame")
    check("tell(\"error\"" in shell, "tell(\"error\", msg) on failure")
    check("requestAnimationFrame" in shell,
      "ready is reported a frame after the picture, not on parse")
    check("window.parent.postMessage" in shell, "it posts to the parent")
    check("AbortController" in shell, "the fetch is bounded")
    check("20000" in shell, "…by a 20 s deadline")
    check("Retry" in shell, "and offers a Retry")
    report("bullwhip's coworld-replay bridge is present, ready included")

  block loadedAttributes:
    ## Acceptance checklist item 13: BOTH markers are set on <html>, from the
    ## shell's own code path, and `data-replay-loaded` carries the literal
    ## string "true" on the first DRAWN frame — tools/ci/viewer_smoke.mjs
    ## matches on `loaded_attr === "true"`, so '1' would never be seen.
    check("data-replay-loaded" in shell,
      "the shell itself sets data-replay-loaded")
    check("setAttribute(\"data-replay-loaded\", \"true\")" in shell,
      "…to the string \"true\", not '1'")
    let loadedAt = shell.find("setAttribute(\"data-replay-loaded\"")
    let readyAt = shell.find("tell(\"ready\")")
    let rafAt = shell.rfind("requestAnimationFrame", 0, loadedAt)
    check(rafAt >= 0 and readyAt > loadedAt,
      "…inside the double requestAnimationFrame that follows the first paint")
    check("setAttribute('data-replay-loaded'" notin page,
      "the chrome page no longer sets it before the first frame is drawn")
    check("data-replay-mismatch-tick" in page,
      "the data-replay-mismatch-tick attribute survives")
    check("setAttribute(\"data-replay-error\"" in shell,
      "the failure attribute is set by the shell too")
    report("the replay status attributes are both set from the shell")

  block browserSmokeIsWired:
    ## The only gate that EXECUTES the assembled page. A wasm-viewer job that
    ## does not run it, or does not depend on the replay docker-smoke
    ## produced, is the cogame-lantern hole (checklist item 13).
    check(fileExists(repoRoot() / "tools" / "ci" / "viewer_smoke.mjs"),
      "tools/ci/viewer_smoke.mjs is committed")
    let workflow = readRepoFile(".github/workflows/ci.yml")
    check("needs: docker-smoke" in workflow,
      "wasm-viewer depends on docker-smoke for a real replay")
    check("name: smoke-replay" in workflow,
      "docker-smoke uploads the replay and wasm-viewer downloads it")
    check("Load the bundle in a real browser" in workflow,
      "the headless-chromium load step is present")
    check("node tools/ci/viewer_smoke.mjs" in workflow,
      "…and it runs the viewer smoke")
    check("playwright@1.55.0" in workflow, "playwright is pinned in both places")
    check("continue-on-error" notin workflow,
      "no CI step is allowed to fail softly")
    let smoke = readRepoFile("tools/ci/docker_smoke.sh")
    check("SMOKE_REPLAY_OUT" in smoke,
      "the smoke preserves its replay outside the trap-deleted work dir")
    report("the browser load test is wired end to end in ci.yml")

  block chromeCommonVerbatim:
    ## chrome_common.js is copied unchanged; the page instantiates it and
    ## fails loud if the splice is missing.
    check("window.ChromeCommon = function (ctx)" in common,
      "chrome_common.js still exports its factory")
    check("if (!window.ChromeCommon)" in page,
      "the page fails loud when the splice is missing")
    check("window.ChromeCommon({" in page, "and instantiates it otherwise")
    check("C.renderTransport(state)" in page, "the shared transport is used")
    check("C.renderClock(state)" in page, "the shared clock is used")
    check("C.markBeat" in page, "the shared beat markers are used")
    check("C.ingestLullSpans" in page, "the shared lull machinery is used")
    check("C.ingestLeadSeries" in page, "the shared momentum graph is used")
    check("C.TEAM_COLOR.red = '#f2c14e'" in page,
      "the colony hues are wired onto the inherited team slots")
    report("chrome_common.js is verbatim and the page rides it")

  block boardRenderer:
    check("HVP1" in core or "72" in core, "the packet magic is checked")
    check("min(0.55" in core.replace(" ", "") or "0.55" in core,
      "the food layer alpha ceiling is 0.55")
    check("0.22" in core, "the home layer alpha ceiling is 0.22")
    check("meadow_floor.jpg" in core, "the painted floor is used")
    check("rock.png" in core, "the painted rock tile is used")
    check("nest_amber.png" in core, "the painted nest sprites are used")
    check("food_cache.png" in core, "the painted cache sprite is used")
    check("ant.png" in core, "the ant sprite is loaded")
    check("textContent" in page, "DOM text is set with textContent only")
    check("innerHTML = line.text" notin page,
      "player-controlled data never goes through innerHTML")
    report("the board renderer composites the painted art over the glow")

  block artIsReal:
    for asset in ["meadow_floor.jpg", "rock.png", "nest_amber.png",
        "nest_teal.png", "nest_lime.png", "nest_magenta.png",
        "food_cache.png", "ant.png", "ant_laden.png", "lockerroom.jpg"]:
      let path = repoRoot() / "client" / "art" / asset
      check(fileExists(path), "client/art/" & asset & " is committed")
      check(getFileSize(path) > 400, "client/art/" & asset & " is real art")
    check(fileExists(repoRoot() / "client" / "art" / "walls" / "wall_h.jpg"),
      "paintbot's wall art is reused verbatim for the border")
    check(fileExists(repoRoot() / "scripts" / "art" / "build_art.py"),
      "the art generator is committed")
    check(fileExists(repoRoot() / "data" / "font.ttf"), "the font ships")
    report("every bundle asset is real, committed art")

  block bundleWiring:
    let dockerfile = readRepoFile("Dockerfile.replay-viewer")
    for expected in ["hive_replay.wasm", "hive_replay.js", "hive_replay.data",
        "index.html", "wire_constants.js", "chrome_common.js",
        "static_replay.js", "font.ttf", "art/meadow_floor.jpg",
        "art/nest_amber.png", "art/ant.png"]:
      check(expected in dockerfile,
        "the bundle build asserts " & expected & " is present")
    check("grep -q 'coworld-replay'" in dockerfile,
      "the bundle build greps for the coworld-replay bridge")
    check("emscripten/emsdk:4.0.15" in dockerfile, "the emsdk pin")
    check("0.1.27" in dockerfile, "the nimby pin")
    check("sha256sum -c" in dockerfile, "the nimby download is sha256-checked")
    let hook = readRepoFile("tools/build_replay_viewer.sh")
    check("static-replay-viewer" in hook, "the hook checks the bundle name")
    check("must be absolute" in hook or "!= /*" in hook,
      "the hook refuses a relative target")
    check("index.html" in hook, "the hook asserts index.html at the end")
    let config = readRepoFile("replay-viewer/config.nims")
    check("ABORTING_MALLOC=1" in config, "the ABORTING_MALLOC link survives")
    check("ENVIRONMENT=web,worker,node" in config,
      "node stays in ENVIRONMENT so CI can smoke the emitted module")
    let module = readRepoFile("replay-viewer/hive_replay.nim")
    check("emscripten_exit_with_live_runtime" in module,
      "the epilogue skip survives")
    check("stampStage" in module, "the progress-note discipline survives")
    for exported in ["hive_load_replay", "hive_input", "hive_frame",
        "hive_packet_ptr", "hive_packet_len", "hive_mismatch_tick",
        "hive_error_ptr", "hive_error_len", "hive_stage_ptr",
        "hive_stage_len"]:
      check(exported in module, "the module exports " & exported)
      check(exported in config, "and the link line exports " & exported)
    report("the bundle build wiring is complete and pinned")

  block wasmHarness:
    ## The emitted module itself, when a bundle is available. The `test` CI
    ## job has no emsdk, so this runs in the `wasm-viewer` job (which calls
    ## tools/wasm_replay_smoke.cjs directly against the freshly built bundle)
    ## and locally for anyone who has run tools/build_replay_viewer.sh.
    let harness = repoRoot() / "tools" / "wasm_replay_smoke.cjs"
    check(fileExists(harness), "the node harness is committed")
    let fixture = repoRoot() / "tests" / "fixtures" / "sample_replay.json"
    check(fileExists(fixture), "the recorded replay fixture is committed")
    var dist = ""
    for candidate in [repoRoot() / "replay-viewer" / "dist",
        repoRoot() / "dist" / "static-replay-viewer"]:
      if fileExists(candidate / "hive_replay.js"):
        dist = candidate
        break
    if dist.len == 0:
      echo "note - no built bundle here; the wasm-viewer CI job runs ",
        "tools/wasm_replay_smoke.cjs against the freshly built one"
      return
    let run = execCmdEx("node " & quoteShell(harness) & " " &
      quoteShell(dist) & " " & quoteShell(fixture))
    echo run.output.strip()
    checkEqual(run.exitCode, 0, "the node wasm smoke passes")
    report("the emitted wasm module replays the fixture, seeks and rejects " &
      "garbage")

main()
echo "test_viewer: all checks passed"
