## The viewer: chrome provenance, the removed and kept elements, the transport
## rules, the beat CSS, the alias-shadowing trap, the 360 px rules and the
## re-mapped spectator vocabulary.

import std/[algorithm, os, sequtils, strutils, tables, unittest]
import crunchy/sha256
import sokoban/[sim, wire_constants]
import helpers

const
  ChromeCommonPath = "client/chrome_common.js"
  PagePath = "client/replay_broadcast.html"
  CorePath = "client/broadcast_core.js"
  BlockPath = "client/sokoban_block.html"
  ChromeCommonSha =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
  ChromeCommonBytes = 40022
  BannerMarker = "SOKOBAN additions to the inherited coworld-ctf chrome"

let page = readFile(PagePath)
let core = readFile(CorePath)

suite "chrome_common is byte-identical":
  test "the inherited chrome is copied, not edited or reformatted":
    let bytes = readFile(ChromeCommonPath)
    check bytes.len == ChromeCommonBytes
    var digest = ""
    for byteValue in sha256(bytes):
      digest.add(toHex(int(byteValue), 2))
    check digest.toLowerAscii() == ChromeCommonSha
    # The alias makes the byte-for-byte pin possible: chrome_common.js reads
    # window.CTF_WIRE for the speed chips and the fps, and renaming inside it
    # would break the sha.
    check "window.CTF_WIRE=window.SOKOBAN_WIRE;" in WireConstantsJs
    check "window.SOKOBAN_WIRE={" in WireConstantsJs

suite "broadcast html is the starter plus a block":
  test "the page is the starter's, with the game block appended under a banner":
    check BannerMarker in page
    let bannerAt = page.find(BannerMarker)
    # Everything the game adds is AFTER the banner.
    check "window.SokobanChrome" in page[bannerAt .. ^1]
    check "skBeat" in page[bannerAt .. ^1]
    # The starter's own structure survives ahead of it.
    for anchor in ["function relayout()", "PB_CTX = {", "core.start();",
                   "window.ChromeCommon", "BroadcastCore.create",
                   "function onFrame(txt)", "function renderScorebug(s)",
                   "dismissLockerRoom", "?embed=1", "classList.toggle('tiny'"]:
      check anchor in page[0 ..< bannerAt]
    # The appended block is the file the build script splices in.
    check fileExists(BlockPath)
    check BannerMarker in readFile(BlockPath)

  test "the page is reproducible from the starter by the committed script":
    check fileExists("scripts/build_broadcast_page.py")
    let script = readFile("scripts/build_broadcast_page.py")
    check "replay_broadcast.html" in script
    check "PaintballChrome" in script
    # A starter MOVES. Without the revision this page was derived from, the
    # provenance claim cannot be re-run at all: coworld-ctf added a TK column
    # to the endcard header after this fork was taken and the script stopped
    # matching its own anchor. The sha is recorded so the rebuild is checkable
    # against the exact bytes the fork was taken from.
    const Marker = "STARTER_SHA = \""
    check Marker in script
    let shaAt = script.find(Marker) + Marker.len
    check script.len > shaAt + 40
    let sha = script[shaAt ..< shaAt + 40]
    for ch in sha:
      check ch in HexDigits
    check script[shaAt + 40] == '"'
    check sha in readFile("README.md")

  test "broadcast_core keeps the starter's parser and pushFeed's signature":
    for anchor in ["function BroadcastCore(config)", "function parse(bytes)",
                   "function ingest(bytes)", "function attachMinimap(surface)",
                   "function setViewportFit()", "function getPaceStats()",
                   "CHROME_SPRITE_ID", "SnappyJS"]:
      check anchor in core
    # The ONLY game-specific reference it ever carried.
    check "window.CTF_WIRE" notin core
    check "window.SOKOBAN_WIRE" in core

suite "no shadowed chrome aliases":
  test "the game block declares no name chrome_common.js already exports":
    let bannerAt = page.find(BannerMarker)
    let gameBlock = page[bannerAt .. ^1]
    let chrome = readFile(ChromeCommonPath)
    var exported: seq[string] = @[]
    let returnAt = chrome.rfind("  return {")
    check returnAt > 0
    for line in chrome[returnAt .. ^1].splitLines():
      for part in line.split(','):
        let pair = part.split(':')
        if pair.len == 2:
          let name = pair[0].strip()
          if name.len > 2 and name.allCharsInSet(
              {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '$'}):
            exported.add(name)
    check exported.len > 10
    for name in exported:
      # The tandem 2026-08-23 hoisting trap: `var markBeat = C.markBeat` in the
      # alias block hoists over a same-named function declaration here.
      check ("function " & name & "(") notin gameBlock
    check "function skBeat(" in gameBlock
    check "function markBeat(" notin gameBlock

suite "beat CSS matches the emitted kinds exactly":
  test "one .beat-marker rule per kind the sim emits, and no others":
    var styled: seq[string] = @[]
    var index = 0
    while true:
      index = page.find(".beat-marker.", index)
      if index < 0:
        break
      index += ".beat-marker.".len
      var kind = ""
      while index < page.len and page[index] in {'a' .. 'z'}:
        kind.add(page[index])
        inc index
      if kind.len > 0 and kind notin styled:
        styled.add(kind)
    styled.sort()
    var emitted: seq[string] = @[]
    for kind in BeatKinds:
      emitted.add(kind)
    emitted.sort()
    check styled == emitted

  test "every beat is a labelled, clickable button that seeks":
    let bannerAt = page.find(BannerMarker)
    let gameBlock = page[bannerAt .. ^1]
    check "createElement('button')" in gameBlock
    check "b.setAttribute('aria-label', label)" in gameBlock
    check "ctx.send('s:' + tick)" in gameBlock

suite "transport, endcard and the 360 px rules":
  test "relayout owns --hudscale, --topband and --band on :root":
    check "root.style.setProperty('--hudscale'" in page
    check "root.style.setProperty('--topband'" in page
    check "root.style.setProperty('--band'" in page
    check "var root = document.documentElement;" in page

  test "the endcard stops at the band and every seek dismisses it":
    check "bottom: var(--band, 0px);" in page
    check "$('endcard').classList.remove('on');" in page

  test "no game-block element is positioned inside the transport band":
    let bannerAt = page.find(BannerMarker)
    let gameBlock = page[bannerAt .. ^1]
    # Every absolutely positioned addition anchors to the TOP band, never the
    # bottom one; the inset keeps the starter's own bottom offset.
    check "top: calc(var(--topband, 0px)" in gameBlock
    check "bottom: 0" notin gameBlock.replace("bottom: 0;\n  width: calc(3", "")

  test "the plate name shrinks instead of collapsing, and labels hide at 640":
    check ".plate-name {" in page
    check "flex: 1 1 auto;" in page
    check "min-width: 3.2em;" in page
    check "@media (max-width: 640px)" in page

  test "the five .tiny rules exist":
    let bannerAt = page.find(BannerMarker)
    let gameBlock = page[bannerAt .. ^1]
    for rule in ["#stage.tiny .sk-alias", "#stage.tiny #sk-ribbon",
                 "#stage.tiny #sk-pips", "#stage.tiny #fpv",
                 "#stage.tiny #fpv-grip"]:
      check rule in gameBlock
    check "HATCH_ALPHA_TINY" in gameBlock

  test "the removed ids appear nowhere and the kept ones are all present":
    for removed in ["id=\"viewpanel\"", "id=\"minimap\"",
                    "id=\"minimap-canvas\"", "id=\"zoombar\"",
                    "id=\"zoom-in\"", "id=\"zoom-out\"", "id=\"zoom-slider\"",
                    "id=\"zoom-read\"", "id=\"povBadge\"", "id=\"fpv-hp\"",
                    "id=\"fpv-gear\"", "id=\"fpv-map\"",
                    "id=\"fpv-map-canvas\""]:
      check removed notin page
    for kept in ["id=\"viewport\"", "id=\"stage\"", "id=\"board\"",
                 "id=\"lightpool\"", "id=\"grain\"", "id=\"lockerroom\"",
                 "id=\"chrome\"", "id=\"scorebug\"", "id=\"plates-l\"",
                 "id=\"plates-r\"", "id=\"clock\"", "id=\"clock-time\"",
                 "id=\"clock-caption\"", "id=\"ffwd-mini\"", "id=\"fpv\"",
                 "id=\"fpv-canvas\"", "id=\"fpv-hud\"", "id=\"fpv-name\"",
                 "id=\"fpv-cap\"", "id=\"fpv-grip\"", "id=\"bannerlane\"",
                 "id=\"killfeed\"", "id=\"mmwarn\"", "id=\"transport\"",
                 "id=\"btn-restart\"", "id=\"btn-back\"", "id=\"btn-play\"",
                 "id=\"btn-fwd\"", "id=\"btn-end\"", "id=\"btn-loop\"",
                 "id=\"btn-skip\"", "id=\"btn-spoilers\"", "id=\"ffwd-chip\"",
                 "id=\"win-chip\"", "id=\"tick-clock\"", "id=\"speedchips\"",
                 "id=\"scrub\"", "id=\"momentum\"", "id=\"scrub-fill\"",
                 "id=\"lulls\"", "id=\"scrub-win\"", "id=\"scrub-head\"",
                 "id=\"endcard\"", "id=\"ec-headline\"", "id=\"ec-wincond\"",
                 "id=\"ec-how\"", "id=\"ec-teams\"", "id=\"ec-replay\"",
                 "id=\"status\""]:
      check kept in page

suite "the static bundle's four viewer files come from ONE starter":
  test "the paintbot-lineage bootstrap and link flags are a matched pair":
    let worker = readFile("replay-viewer/static_replay_worker.js")
    let shell = readFile("replay-viewer/static_replay.js")
    let flags = readFile("replay-viewer/config.nims")
    # paintbot-lineage: the worker waits for onRuntimeInitialized and the
    # module is emitted NON-modularized. A MODULARIZE/EXPORT_NAME factory here
    # would hang on "Loading replay..." forever (cogame-lantern, 2026-08-23).
    check "Module.onRuntimeInitialized" in worker
    check "MODULARIZE" notin flags
    check "EXPORT_NAME" notin flags
    check "-s ABORTING_MALLOC=1" in flags
    check "--preload-file" in flags
    check "-s ENVIRONMENT=web,worker,node" in flags
    for fn in ["_sokoban_load_replay", "_sokoban_frame", "_sokoban_input",
               "_sokoban_packet_ptr", "_sokoban_packet_len",
               "_sokoban_mismatch_tick", "_sokoban_error_ptr",
               "_sokoban_error_len", "_sokoban_stage_ptr",
               "_sokoban_stage_len"]:
      check fn in flags
    check "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./sokoban_replay.js')" in worker
    # The load and failure signals the harness reads.
    check "data-replay-loaded" in shell
    check "data-replay-error" in shell

  test "the wasm entry exports exactly the functions the flags name":
    let entry = readFile("replay-viewer/sokoban_replay.nim")
    for fn in ["sokoban_load_replay", "sokoban_frame", "sokoban_input",
               "sokoban_packet_ptr", "sokoban_packet_len",
               "sokoban_mismatch_tick", "sokoban_error_ptr",
               "sokoban_error_len", "sokoban_stage_ptr",
               "sokoban_stage_len"]:
      check ("exportc: \"" & fn & "\"") in entry
    check "emscripten_exit_with_live_runtime" in entry
    check "stampStage" in entry

suite "endcard labels":
  test "the paintbot spectator vocabulary is gone":
    # Scoped to the strings a SPECTATOR reads: the inherited chrome's own
    # identifiers (teamCol, s.teams, .team-name) are structural and stay.
    for forbidden in [">Lives<", "LIVES LEAD", "<span>Clstr</span>",
                      "<span>Cap</span>", "<span>K</span>", "<span>D</span>",
                      "Filling hoppers with fresh paint", "Lives left",
                      "Hill time", "In the locker room", ">EYES<",
                      "showing recorded inputs", ">\U0001f441 POV lens",
                      "Spoilers: kills / flag story"]:
      check forbidden notin page

  test "each re-mapped string is present, and the plate labels exactly once":
    for replacement in ["<span class=\"solved-label\">Solved</span>",
                        "<span class=\"solved-label pb-lbl\">Level</span>",
                        "<span class=\"fl-cap\">Pushes made</span>",
                        "<span class=\"momentum-label\">CRATES PARKED</span>",
                        "Sizing up the first level&hellip;",
                        ">Waiting for the cog<",
                        "Replay hash mismatch \u2014 showing recorded moves",
                        "<div class=\"fpv-cap\" id=\"fpv-cap\">DEAD SQUARES" &
                          "</div>",
                        "Spoilers: solved / deadlocked levels on the timeline"]:
      check page.count(replacement) == 1
    # The appended endcard re-states the "Levels solved" caption when it
    # rebuilds #ec-teams, so this one is present in both the inherited builder
    # and the game block.
    check page.count("<span class=\"fl-cap\">Levels solved</span>") == 2

suite "the LLM-text class is covered, not merely flagged":
  test "the say row has a reserved band sized from the server's own cap":
    let bannerAt = page.find(BannerMarker)
    let gameBlock = page[bannerAt .. ^1]
    # The inherited feed row is `white-space: nowrap` and sized to content —
    # right for a pre-bounded 10-character name, wrong for a 140-rune
    # sentence, which at 360 px grows leftward off the frame. The say row
    # wraps inside the column #killfeed already reserves.
    check "#killfeed .feed-row.say" in gameBlock
    check "white-space: normal;" in gameBlock
    check "MaxSayRunes" in gameBlock

  test "the worst-case fixture drives the shipped page and measures it":
    let fixture = readFile("tools/ci/renderer_fixture.html")
    # It loads the SHIPPED bundle rather than re-implementing the drawing.
    check "./index.html?replay=" in fixture
    # Its own string is the server's cap, and it asserts it survived at full
    # length — a quietly shortened remark leaves a fixture passing while
    # testing nothing.
    check "Array.from(SAY).slice(0, 140)" in fixture
    check "feed-row.say" in fixture
    check "was shortened to" in fixture
    check "data-replay-error" in fixture
    # And it mirrors every line the page laid out into a MAIN-THREAD 2D
    # canvas, which is the only text `viewer_smoke.mjs` can see: this viewer
    # draws its board in a Worker's OffscreenCanvas, where the smoke reports
    # `total: 0` and covers nothing.
    check "getContext('2d')" in fixture
    check "fillText" in fixture
    let workflow = readFile(".github/workflows/ci.yml")
    check "renderer_fixture.html" in workflow
    check workflow.count("\n            --strict-text-bounds") == 2

suite "the appended block draws the readouts the design names":
  test "ribbon, pips, inset, clock, plate, feed and endcard are all there":
    let bannerAt = page.find(BannerMarker)
    let gameBlock = page[bannerAt .. ^1]
    for anchor in ["sk-ribbon", "sk-pips", "skInset", "skClock",
                   "skPlate", "skEndcard", "DEADLOCK CREATED",
                   "CRATE PARKED", "SOLVED ", "MISSED THE CALL",
                   "crate-chip", "OF 4 PARKED"]:
      check anchor in gameBlock
