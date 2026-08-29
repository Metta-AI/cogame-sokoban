#!/usr/bin/env node
// Runs the SHIPPED broadcast page in a real browser with the wasm runtime
// stubbed, so the page's own boot path, the inherited chrome and the appended
// SOKOBAN block all execute and any thrown error is caught before CI.
//
//   node tools/ci/page_smoke.mjs
//
// It is a LOCAL developer gate, not a CI job: `ci.yml`'s wasm-viewer job runs
// the real bundle against the real replay. This one exists because the wasm
// module needs emsdk and a page-level exception (a deleted declaration still
// referenced, a shadowed alias) is invisible to `node --check`.

const playwright = await import(process.env.PLAYWRIGHT_MODULE || "playwright");
const chromium = (playwright.chromium || playwright.default.chromium);
import { readFileSync } from "node:fs";
import { createServer } from "node:http";

const page_html = readFileSync("client/replay_broadcast.html", "utf8")
  .replace("<!-- WIRE_CONSTANTS -->", '<script src="./wire_constants.js"></script>')
  .replace("<!-- CHROME_COMMON -->", '<script src="./chrome_common.js"></script>')
  .replace("<!-- BROADCAST_CORE -->", '<script src="./stub_core.js"></script>');

const files = {
  "/index.html": [page_html, "text/html"],
  "/chrome_common.js": [readFileSync("client/chrome_common.js", "utf8"),
                        "application/javascript"],
  "/wire_constants.js": [readFileSync("wire_constants.js", "utf8"),
                         "application/javascript"],
  "/stub_core.js": [`
    // The wasm runtime, stubbed: BroadcastCore's API surface with no drawing.
    window.SokobanStaticReplay = null;
    window.BroadcastCore = { create: function (config) {
      window.__cfg = config;
      return {
        start: function () { window.__started = true; },
        stop: function () {},
        ingest: function () {},
        sendCommand: function (c) { (window.__cmds = window.__cmds || []).push(c); },
        clickMap: function () {},
        attachMinimap: function () {},
        setViewportFit: function () {},
        setViewportSize: function () {},
        zoomAt: function () {}, setZoom: function () {}, panBy: function () {},
        panByMap: function () {}, panTo: function () {}, resetView: function () {},
        getTransform: function () {
          return { zoom: 1, minZoom: 1, maxZoom: 1, scale: 1, offsetX: 0,
                   offsetY: 0, nativeW: 480, nativeH: 480 };
        },
        getPaceStats: function () { return { draws: 0 }; }
      };
    } };
  `, "application/javascript"]
};

const server = createServer((req, res) => {
  const key = req.url.split("?")[0] === "/" ? "/index.html" : req.url.split("?")[0];
  const hit = files[key];
  if (!hit) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": hit[1] });
  res.end(hit[0]);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const browser = await chromium.launch();
const tab = await browser.newPage({
  viewport: { width: Number(process.env.SK_WIDTH || 1280),
              height: Number(process.env.SK_HEIGHT || 720) } });
const errors = [];
tab.on("pageerror", (e) => errors.push("pageerror: " + e.message));
tab.on("console", (m) => {
  // Asset 404s are expected: this harness serves only the page and its two
  // scripts, not the locker-room art the real bundle ships.
  if (m.type() === "error" && !/Failed to load resource/.test(m.text())) {
    errors.push("console: " + m.text());
  }
});
await tab.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: "load" });
await tab.waitForTimeout(400);

const started = await tab.evaluate(() => window.__started === true);
const hasChrome = await tab.evaluate(() => typeof window.SokobanChrome === "object");

// Drive the real page with the worst-case frame the renderer fixture uses.
const frame = JSON.parse(readFileSync(process.argv[2] || "/tmp/frame.json", "utf8"));
const skipOver = process.env.SK_SKIP_GAMEOVER === "1";
const drove = await tab.evaluate(([state, process_gameover_skip]) => {
  try {
    // The stub captured BroadcastCore's config, so `onText` is the page's own
    // real frame path: the inherited chrome AND the appended block both run,
    // exactly as they do against the wasm runtime.
    const playing = JSON.parse(JSON.stringify(state));
    playing.events = state.__events || [];
    window.__cfg.onText(JSON.stringify(playing));
    if (!process_gameover_skip) {
      const over = JSON.parse(JSON.stringify(state));
      over.ph = "gameover";
      over.events = [];
      window.__cfg.onText(JSON.stringify(over));
    }
    return "ok";
  } catch (err) { return String(err && err.message || err); }
}, [frame, skipOver]);

// The locker-room curtain has a minimum dwell before it fades on the first
// frame; wait past it so the screenshot shows the board chrome.
await tab.waitForTimeout(2600);

const readouts = await tab.evaluate(() => ({
  clock: (document.getElementById("clock") || {}).textContent,
  ribbon: (document.getElementById("sk-ribbon") || {}).textContent,
  pips: (document.getElementById("sk-pips") || {}).childElementCount,
  beats: document.querySelectorAll("#scrub .beat-marker").length,
  feed: document.querySelectorAll("#killfeed *").length,
  endcard: (document.getElementById("endcard") || {}).className,
  plate: (document.getElementById("name-red") || {}).textContent,
  chips: document.querySelectorAll(".crate-chip.on").length
}));

await tab.screenshot({ path: process.argv[3] || "/tmp/page_smoke.png", fullPage: false });
await browser.close();
server.close();

console.log(JSON.stringify({ started, hasChrome, drove, readouts, errors }, null, 2));
if (!started || !hasChrome || drove !== "ok" || errors.length) process.exit(1);
