#!/usr/bin/env python3
"""Derives client/replay_broadcast.html from the inherited coworld-ctf page.

The page is NOT written from scratch. It is the starter's broadcast page with

  * exactly the elements the design note's Viewer section lists as REMOVED cut
    out (markup, CSS, wiring and test ids),
  * the spectator-chrome vocabulary re-mapped (the design note's re-labelling
    table), and
  * the SOKOBAN game block appended under its banner comment, spliced in
    through the starter's own `window.PaintballChrome` hook renamed
    `window.SokobanChrome`.

A page written from scratch that reuses the starter's ids is a rewrite and
fails review (cogame-gridlock, 2026-08-23), so this script exists to make the
provenance mechanical and checkable: run it against the starter and it
reproduces the shipped file byte for byte.

THE STARTER REVISION THIS PAGE WAS DERIVED FROM is recorded here, because a
starter moves: `client/replay_broadcast.html` in this repo is exactly this
script's output against `Metta-AI/coworld-ctf` at

    STARTER_SHA = a7484eb47b14bde20678ff106c684a633b4f294c   (2026-08-28)

Re-verify it with:

    git -C /workspace/starters/coworld-ctf show \
        a7484eb:client/replay_broadcast.html > /tmp/starter_page.html
    python3 scripts/build_broadcast_page.py /tmp/starter_page.html \
        /tmp/rebuilt.html client/sokoban_block.html
    diff /tmp/rebuilt.html client/replay_broadcast.html    # empty

It also runs against a LATER starter revision — the anchors that the starter
has since edited are matched by shape rather than by exact text — but the
output then carries the starter's own later changes and is no longer identical
to the shipped page. That is the point: the diff is the starter's, not this
fork's.

    python3 scripts/build_broadcast_page.py \
        /workspace/starters/coworld-ctf/client/replay_broadcast.html \
        client/replay_broadcast.html client/sokoban_block.html
"""

import re
import sys

STARTER_SHA = "a7484eb47b14bde20678ff106c684a633b4f294c"


def cut(text, start, end, note, inclusive_end=True):
    """Deletes the span from `start` to `end`, asserting both anchors exist."""
    i = text.index(start)
    j = text.index(end, i)
    if inclusive_end:
        j += len(end)
    removed = text[i:j]
    assert removed, note
    return text[:i] + text[j:]


def swap(text, old, new, count=None):
    found = text.count(old)
    assert found, "anchor not found: " + old[:70]
    if count is not None:
        assert found == count, "%d occurrences of %r, expected %d" % (
            found, old[:50], count)
    return text.replace(old, new)


def swap_re(text, pattern, new, count=1):
    """Replaces an anchor the starter still edits, matched by SHAPE.

    An exact-text anchor over a line the starter is still changing turns this
    script into a one-revision tool: coworld-ctf added a `TK` column to the
    endcard header after this fork was taken (`ed3bd67`) and the exact anchor
    stopped matching, so the provenance claim became unrunnable. The columns
    are replaced wholesale here anyway, so the anchor only has to identify the
    line, not spell it.
    """
    found = re.findall(pattern, text)
    assert found, "regex anchor not found: " + pattern[:70]
    assert len(found) == count, "%d matches of %r, expected %d" % (
        len(found), pattern[:50], count)
    return re.sub(pattern, new.replace("\\", "\\\\"), text)


def main():
    src, dst, block_path = sys.argv[1], sys.argv[2], sys.argv[3]
    page = open(src, encoding="utf-8").read()

    # ---------------------------------------------------------------- CSS ---
    page = cut(page, "#povBadge {", "#povBadge.on { display: flex; }\n",
               "povBadge CSS")
    page = cut(page, ".fpv-hp {", ".fpv-dead .fpv-hp, .fpv-dead .fpv-gear "
               "{ opacity: 0.4; }\n", "fpv hp/gear CSS")
    page = cut(page, "/* Un-fogged tactical minimap inset",
               "/* ---------- 4b. VIEW CONTROLS", "fpv-map CSS",
               inclusive_end=False)
    page = cut(page, "/* ---------- 4b. VIEW CONTROLS",
               "#zoom-read.zoomed { color: var(--amber); }\n",
               "viewpanel + zoombar CSS")
    page = cut(page, "/* Opt-OUT of the #viewpanel overlay",
               "body[data-noviewpanel] #viewpanel { display: none !important; }\n",
               "viewpanel opt-out CSS")
    page = cut(page, "#endcard .ec-heart {",
               "/* loop countdown \u2014 present only while the server holds "
               "the end segment */", "ec-heart CSS", inclusive_end=False)
    page = cut(page, "/* kill ticks are short and colored",
               "/* winner cap: a flat block just past the track",
               "kill/steal/return/capture beat CSS", inclusive_end=False)

    # ------------------------------------------------------------- markup ---
    page = cut(page, "    <!-- View controls: zoom the board",
               "    </div>\n\n    <div id=\"mmwarn\">",
               "viewpanel markup", inclusive_end=False)
    page = swap(page, "    <div id=\"povBadge\">"
                "\U0001f441 POV lens \u2014 click to clear</div>\n", "", 1)
    page = swap(page, "        <span class=\"fpv-hp\" id=\"fpv-hp\"></span>\n"
                "        <span class=\"fpv-gear\" id=\"fpv-gear\"></span>\n",
                "", 1)
    page = cut(page, "      <!-- Un-fogged tactical minimap",
               "      <div class=\"fpv-cap\" id=\"fpv-cap\">",
               "fpv-map markup", inclusive_end=False)

    # ----------------------------------------------------------- the JS -----
    # The whole raycast first-person pipeline. This game is PERFECT
    # INFORMATION: there is nothing to occlude, so it is deleted outright
    # rather than left as unreachable code. The #fpv CANVAS is reused (as the
    # dead-square inset); the raycaster is not.
    page = cut(page, "  function renderFpv(s) {",
               "  function renderMismatch(s) {",
               "raycast FPV pipeline", inclusive_end=False)
    page = swap(page, """  function renderPov(s) {
    var badge = $('povBadge');
    badge.classList.toggle('on', s.pov >= 0);
    if (s.pov >= 0) badge.textContent = '\U0001f441 POV: ' + shortName(rosterName(s, s.pov)) + ' \u2014 click to clear';
    renderFpv(s);
  }
""", """  // With ONE seat there is nothing to select, so the POV badge and the
  // raycast lens are gone; the #fpv panel is repurposed wholesale as the
  // dead-square inset, which the appended SOKOBAN block draws.
  function renderPov(s) { return s; }
""", 1)
    page = swap(page, "  $('povBadge').addEventListener('click', "
                "function () { send('v:-1'); });\n", "", 1)

    # The board is a FIXED 10 x 10 grid with no off-frame area, so there is
    # nothing to zoom into and nothing to pan across: the z/x/0 and arrow keys
    # go with the #viewpanel wiring that owned ZOOM_STEP and panCellBoardPx.
    page = cut(page, "    // Board zoom rides z/x/0",
               "    else if (k >= '1' && k <= '9') send(k);",
               "board zoom + pan keys", inclusive_end=False)
    page = cut(page, "  // ---- view controls: zoom cluster + minimap",
               "  canvas.addEventListener('dblclick', function (ev) {",
               "zoom bar + minimap wiring", inclusive_end=False)
    page = swap(page, """    onFirstFrame: function () { core.setViewportFit(); syncViewUi(); },""",
                """    onFirstFrame: function () { core.setViewportFit(); },""", 1)
    page = swap(page, """    onTransform: function (t) { syncViewUi(t); }""",
                """    onTransform: function (t) { syncTouchAction(t); }""", 1)
    page = cut(page, "  // ?viewpanel=0 hides the #viewpanel overlay",
               "  // Tick deep-link (?t=<tick>)",
               "viewpanel query-param wiring", inclusive_end=False)


    # The first-person map ingest reads `s.fpmap`, which this game never emits
    # (perfect information: there is no fog layer to silhouette). Deleted, not
    # left as unreachable code.
    page = cut(page, "  // The server ships the static minimap wall silhouette",
               "  // ---------- scorebug ----------", "fp map ingest",
               inclusive_end=False)
    page = swap(page, "    ingestFpMap(s);\n", "", 1)
    page = swap(page, """    <!-- First-person picture-in-picture: the selected seat's Wolfenstein-style
         raycast view, shown only while a player is in POV. A window into what
         that soldier sees down the barrel, riding alongside their top-down fog.
         Its own inset tactical map (bottom-left) shows the seat's position and
         vision cone against the WHOLE un-fogged arena, so the viewer always
         knows where the EYES are looking and standing. -->""",
                """    <!-- The dead-square inset. The starter's first-person panel, repurposed
         wholesale: the same 10x10 grid stripped to walls, marked squares, dead
         squares and crates, so the geometry of the trap is legible even when
         the main board is busy. Draggable and resizable by the starter's own
         grip. This game is PERFECT INFORMATION, so nothing here is a lens on
         a fogged view - it is a second, simplified read of the same board. -->""", 1)


    # The eye-level billboard art belonged to the raycaster, which is gone. The
    # COG_BASE path expression stays: the locker-room curtain and the appended
    # block both resolve their assets through it, and it is the ONE place that
    # maps the page's three delivery routes.
    page = cut(page, "  var COG_ART = {}, COG_ART_GUN = {};",
               "  // The front masters are trimmed to their opaque box",
               "eye-level billboard art", inclusive_end=False)
    page = cut(page, "  // The front masters are trimmed to their opaque box",
               "  // Engine-authoritative wire constants (read via the shared "
               "chrome;", "billboard trim + depth-dim scratch",
               inclusive_end=False)
    page = swap(page, "window.CtfStaticReplay", "window.SokobanStaticReplay")
    # One cog, and it is red: the blue/green/yellow locker-room webps are not
    # shipped, so the curtain seats the red bot alone.
    page = cut(page, "      green:  { ax: 22.83", "      red:    { ax: 79.03",
               "locker-room bot roster", inclusive_end=False)
    page = swap(page, "    ['green', 'blue', 'yellow', 'red'].forEach"
                "(function (bot) {", "    ['red'].forEach(function (bot) {", 1)
    page = swap(page, "      red:    { ax: 79.03", "      red:    { ax: 50.00", 1)

    # -------------------------------------------- spectator vocabulary ------
    page = swap(page, "Filling hoppers with fresh paint&hellip;",
                "Sizing up the first level&hellip;")
    page = swap(page, "Filling hoppers with fresh paint\u2026",
                "Sizing up the first level\u2026")
    page = swap(page, ">In the locker room<", ">Waiting for the cog<", 1)
    page = swap(page,
                "Replay hash mismatch \u2014 showing recorded inputs",
                "Replay hash mismatch \u2014 showing recorded moves", 1)
    page = swap(page, "<div class=\"fpv-cap\" id=\"fpv-cap\">EYES</div>",
                "<div class=\"fpv-cap\" id=\"fpv-cap\">DEAD SQUARES</div>", 1)
    page = swap(page,
                "title=\"Spoilers: kills / flag story / winner on the "
                "timeline ahead of the playhead (o)\"",
                "title=\"Spoilers: solved / deadlocked levels on the timeline "
                "ahead of the playhead (o)\"", 1)
    page = swap(page, "<span class=\"momentum-label\">LIVES LEAD</span>",
                "<span class=\"momentum-label\">CRATES PARKED</span>", 1)
    page = swap(page, "<span class=\"lives-label\">Lives</span>",
                "<span class=\"solved-label\">Solved</span>", 1)
    page = swap(page, "<span class=\"lives-label pb-lbl\">Hill</span>",
                "<span class=\"solved-label pb-lbl\">Level</span>", 1)
    page = swap(page, "<span class=\"fl-cap\">Lives left</span>",
                "<span class=\"fl-cap\">Levels solved</span>", 1)
    page = swap(page, "<span class=\"fl-cap\">Hill time</span>",
                "<span class=\"fl-cap\">Pushes made</span>", 1)
    # The ctf endcard header, whatever columns the starter currently gives it
    # (it gained a TK column in ed3bd67): every column is replaced.
    page = swap_re(page,
                   r"'<div class=\"ec-thead\"><span>Player</span>"
                   r"(?:<span>[A-Za-z]+</span>)+</div>'",
                   "'<div class=\"ec-thead\"><span>Level</span>"
                   "<span>Tier</span><span>Result</span><span>Moves</span>"
                   "<span>Crates</span></div>'")
    page = swap(page,
                "'<div class=\"ec-thead\"><span>Cog</span><span>Tags</span>"
                "<span>Out</span><span>Paint</span></div>'",
                "'<div class=\"ec-thead\"><span>Cog</span><span>Solved</span>"
                "<span>Pushes</span><span>Score</span></div>'", 1)
    page = swap(page, ".lives-label {", ".solved-label {")
    page = swap(page, "<div class=\"flagicon\" id=\"flag-'",
                "<div class=\"crates\" id=\"flag-'", 1)
    page = swap(page, ".flagicon {", ".crates {")
    page = swap(page, ".flagicon ", ".crates ")
    page = swap(page,
                "'<span class=\"team-name\" id=\"name-' + team + '\">'",
                "'<span class=\"team-name plate-name\" id=\"name-' + team + "
                "'\">'", 1)

    # `buildFlag` keeps its name, its call site and its `.carrier-tag` child
    # (updateFlag writes into it); only what it DRAWS changes, from paintbot's
    # flag to this game's four crate chips.
    page = cut(page, "  // ---- flag icon svg", "  // (speed chips are built",
               "buildFlag body", inclusive_end=False)
    page = swap(page, "  // (speed chips are built", """  // ---- crate chips (four, filled as crates are parked) ----
  // The starter's flag glyph, retargeted: same element, same id, same
  // `.carrier-tag` child, so every call site in the inherited chrome still
  // works; only what it draws changes.
  function buildFlag(el, color) {
    var chips = '';
    for (var i = 0; i < 4; i++) {
      chips += '<i class="crate-chip" data-i="' + i + '"></i>';
    }
    el.innerHTML = chips + '<div class="carrier-tag"></div>';
    el.style.setProperty('--crate-col', color || '#e8a33d');
  }

  // (speed chips are built""", 1)

    # -------------------------------------------------- the appended block --
    marker = "<!-- ============================================================\n" \
             "     PAINTBALL additions to the inherited coworld-ctf chrome"
    index = page.index(marker)
    page = page[:index] + open(block_path, encoding="utf-8").read()
    page = swap(page, "window.PaintballChrome", "window.SokobanChrome")
    page = swap(page, "PB_MODE && window.SokobanChrome",
                "SK_READY && window.SokobanChrome")
    page = swap(page, "if (!PB_MODE && s.regime !== undefined) PB_MODE = true;",
                "if (!SK_READY && s.sok !== undefined) SK_READY = true;", 1)
    page = swap(page, "  var PB_MODE = false;", "  var PB_MODE = false;\n"
                "  // Latched on the first frame that carries this game's own\n"
                "  // `sok` payload, exactly as PB_MODE latches on `regime`.\n"
                "  var SK_READY = false;", 1)
    open(dst, "w", encoding="utf-8").write(page)
    print("wrote", dst, len(page), "bytes")


if __name__ == "__main__":
    main()
