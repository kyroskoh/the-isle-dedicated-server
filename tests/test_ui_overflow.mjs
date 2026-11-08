// tests/test_ui_overflow.mjs - layout edge cases of the web UI (PRD UI-02).
// Seeds deliberately long data (server name, class names, plugin names and descriptions,
// snapshot names, unbroken setting values, log lines, RCON replies) into a throw-away copy
// of the repo, then visits every page, dialog and state at widths from 1440 px down to 320 px,
// in light and dark, and fails on:
//   - an element that spills outside its box (card, chip, button, badge, list row, cell, dialog ...)
//   - text that overflows its element, or is clipped without an ellipsis
//   - text truncated with an ellipsis but no tooltip (title) to read it in full
//   - horizontal scrolling of the page
//   node tests/test_ui_overflow.mjs
import { spawn } from "node:child_process";
import { cpSync, mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require("playwright")); } catch { ({ chromium } = await import("playwright")); }

const SRC = dirname(dirname(fileURLToPath(import.meta.url)));
const PY = process.env.PYTHON || (process.platform === "win32" ? "python" : "python3");
const TOKEN = "overflow-token-0123456789abcdef";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => res(p)); }); });

// --------------------------------------------- a repo copy with long data
const dir = mkdtempSync(join(tmpdir(), "isle-overflow-"));
const REPO = join(dir, "repo");
for (const part of ["VERSION", "config", "plugins", "tools", "ui", "tests/fixtures"]) cpSync(join(SRC, part), join(REPO, part), { recursive: true });
const LONG = "Supercalifragilisticexpialidociousosaurus";
const classes = readFileSync(join(REPO, "config", "classes.txt"), "utf8")
  .replace("# Carnivores\n", `# Carnivores\n${LONG}Rex     carnivore\nVeryLongNameWithoutAnySpacesAtAllForTesting   omnivore\n`);
writeFileSync(join(REPO, "config", "classes.txt"), classes);
writeFileSync(join(REPO, "config", "rosters", "an-extremely-long-roster-preset-name.txt"),
  "# Roster: an-extremely-long-roster-preset-name - " + "a description that keeps going and going ".repeat(4) + "\nTyrannosaurus\n");
writeFileSync(join(REPO, "config", "profiles", "an-extremely-long-profile-name-for-layout-testing.conf"),
  "# Profile: an-extremely-long-profile-name-for-layout-testing - " + "long description ".repeat(12) + "\n" +
  "EXTRA_GAME_SESSION_SETTINGS=" + "bSomeVeryLongUnrealSettingName=true|".repeat(6) + "\nGROWTH_MULTIPLIER=1\n");
const cat = JSON.parse(readFileSync(join(REPO, "plugins", "catalog.json"), "utf8"));
cat.plugins.push({ name: "an-extraordinarily-long-plugin-name-that-never-ends", source: "builtin:none", version: "10.20.300-beta.4",
  description: "A".repeat(90) + " and then " + "words ".repeat(30), tags: ["averyveryverylongtagwithoutspaces", "x"] });
cat.presets["an-extremely-long-plugin-preset-name"] = ["restart-countdown"];
writeFileSync(join(REPO, "plugins", "catalog.json"), JSON.stringify(cat, null, 1));

mkdirSync(join(dir, "config"));
const conf = join(dir, "config", "server.conf");
writeFileSync(conf, readFileSync(join(REPO, "config", "server.conf.example"), "utf8")
  .replace(/^RCON_PASSWORD=.*$/m, "RCON_PASSWORD=pw-overflow")
  .replace(/^SERVER_NAME=.*$/m, 'SERVER_NAME="Gondwa Survival | Realism | Weekly wipes | discord.gg/an-incredibly-long-invite-code | EU-West-Frankfurt"')
  .replace(/^EXTRA_ARGS=.*$/m, "EXTRA_ARGS=-log" + "-AVeryLongArgumentWithoutSpaces".repeat(6))
  .replace(/^SERVER_DIR=.*$/m, "SERVER_DIR=/srv/games/the-isle/an/unusually/deep/folder/structure/that/goes/on/and/on/theisle-server")
  .replace(/^ADMIN_STEAM_IDS=.*$/m, "ADMIN_STEAM_IDS=" + Array.from({ length: 12 }, (_, i) => "765611980000000" + String(10 + i)).join(","))
  .replace(/^ALLOWED_CLASSES=.*$/m, `ALLOWED_CLASSES=${LONG}Rex,Tyrannosaurus`));
const logFile = join(dir, "server.log");
writeFileSync(logFile, Array.from({ length: 50 }, (_, i) => i % 7 ? `[2026.11.08-12.00.${String(i).padStart(2, "0")}] LogTheIsle: line ${i}` :
  "X".repeat(400)).join("\n") + "\n");

const port = await freePort();
const env = { ...process.env, ISLE_UI_TOKEN: TOKEN, ISLE_LOG_DIR: join(dir, "logs"), FAKE_STATE_DIR: dir, FAKE_LAUNCHER_LOG: join(dir, "calls.log"), FAKE_DELAY: "0.1",
  FAKE_LOG_FILE: logFile };
const api = spawn(PY, [join(REPO, "tools", "isle_api.py"), "--conf", conf, "--launcher", join(REPO, "tests", "fixtures", "fake-launcher.py"),
  "--port", String(port), "--snapshot-dir", join(dir, "snapshots")], { env, stdio: "ignore" });
const BASE = `http://127.0.0.1:${port}`;
for (let i = 0; i < 100; i++) { try { if ((await fetch(BASE + "/api/v1/health")).ok) break; } catch { /* starting */ } await sleep(100); }
const call = async (method, path, body) => (await fetch(BASE + "/api/v1" + path, { method,
  headers: { Authorization: "Bearer " + TOKEN, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined })).json();
const job = await call("POST", "/snapshots", { include: ["worlds", "settings", "overrides", "plugins", "backups"] });
for (let i = 0; i < 50 && (await call("GET", "/jobs/" + job.id)).state === "running"; i++) await sleep(100);
const snaps = (await call("GET", "/snapshots"));
if (snaps.length) cpSync(join(dir, "snapshots", snaps[0].name), join(dir, "snapshots", "theisle-snapshot_20261108_120000_before-the-big-migration-to-the-new-dedicated-box.tar.gz"));
await call("POST", "/server/start");
await sleep(800);

// ----------------------------------------------------------------- audit
function audit() {
  const BOX = ".card,.chip,.btn,.pill,.badge,.list li,.toast,dialog,.sticky-bar,.topbar,.op,.segmented,.input-group,.hero,td,th,.nav a,.brand,.kv,.row,.page-head";
  const desc = (e) => e.tagName.toLowerCase() + (e.id ? "#" + e.id : "") + (e.className && typeof e.className === "string" ? "." + e.className.trim().split(/\s+/).join(".") : "")
    + (e.textContent ? ` "${e.textContent.trim().slice(0, 40)}"` : "");
  const shown = (e) => { const r = e.getBoundingClientRect(); const cs = getComputedStyle(e); return r.width > 0 && r.height > 0 && cs.visibility !== "hidden" && cs.display !== "none" && !e.closest("[hidden]"); };
  const exempt = (e) => e.closest("pre, .table-wrap, textarea, select, option, input, svg, .sr-only, .progress, .switch .track");
  const out = new Set();
  for (const el of document.querySelectorAll("body *")) {
    if (!shown(el) || exempt(el)) continue;
    const box = el.parentElement && el.parentElement.closest(BOX);
    if (box && shown(box)) {
      const r = el.getBoundingClientRect(), b = box.getBoundingClientRect();
      const over = Math.max(r.right - b.right, b.left - r.left);
      if (over > 1) out.add(`${desc(el)} spills out of ${desc(box)} by ${Math.round(over)}px`);
    }
    const cs = getComputedStyle(el);
    if (el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 1 && !["auto", "scroll"].includes(cs.overflowX)) {
      if (cs.overflowX === "visible") out.add(`${desc(el)}: content overflows (${el.scrollWidth} > ${el.clientWidth})`);
      else if (cs.textOverflow !== "ellipsis") out.add(`${desc(el)}: clipped without an ellipsis`);
      else if (!el.closest("[title]")) out.add(`${desc(el)}: truncated without a title tooltip`);
    }
  }
  // tables must fit: on wide screens the columns wrap their data, on phones rows stack
  for (const t of document.querySelectorAll(".table-wrap")) {
    if (shown(t) && t.scrollWidth > t.clientWidth + 1) out.add(`${desc(t).slice(0, 60)}: table needs sideways scrolling (${t.scrollWidth} > ${t.clientWidth})`);
  }
  // a normal-length word split across lines ("Outp/ut", "N/a/t/i/v/e") means its box got too narrow
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const el = node.parentElement;
    if (!el || !node.textContent.trim() || exempt(el) || !shown(el)) continue;
    const re = /[^\s\-/|]+/g; let m;  // hyphens, slashes and bars are normal break points
    while ((m = re.exec(node.textContent))) {
      if (m[0].length < 2 || m[0].length > 20) continue;  // very long tokens (IDs, paths) may wrap
      const range = document.createRange();
      range.setStart(node, m.index); range.setEnd(node, m.index + m[0].length);
      const tops = new Set([...range.getClientRects()].filter((r) => r.width > 0).map((r) => Math.round(r.top)));
      if (tops.size > 1) { out.add(`${desc(el)}: the word "${m[0]}" breaks across lines`); break; }
    }
  }
  if (document.documentElement.scrollWidth > window.innerWidth + 1) {
    const wide = [...document.querySelectorAll("body *")].filter((e) => shown(e) && e.getBoundingClientRect().right > window.innerWidth + 1 && !e.closest(".table-wrap, pre"))
      .map((e) => desc(e).slice(0, 60)).slice(-3);
    out.add(`page scrolls horizontally (${document.documentElement.scrollWidth} > ${window.innerWidth}): ${wide.join(" | ")}`);
  }
  return [...out];
}

const browser = await chromium.launch();
let fails = 0;
const report = (label, found) => {
  if (found.length) { fails++; console.log(`  FAIL ${label}`); found.slice(0, 8).forEach((f) => console.log("       " + f)); if (found.length > 8) console.log(`       ... ${found.length - 8} more`); }
  else console.log(`  PASS ${label}`);
};
const settle = async (page) => {
  for (let i = 0; i < 80; i++) { if (await page.evaluate(() => !document.querySelector("#content [role=status]"))) break; await sleep(100); }
  await sleep(150);
};
const ROUTES = ["", "settings", "players", "roster", "profiles", "plugins", "snapshots", "logs", "console"];
const WIDTHS = [1440, 1280, 1024, 820, 600, 390, 320];
try {
  for (const scheme of ["light", "dark"]) {
    for (const width of WIDTHS) {
      const ctx = await browser.newContext({ viewport: { width, height: 900 }, colorScheme: scheme, reducedMotion: "reduce" });
      const page = await ctx.newPage();
      await page.goto(BASE + "/");
      if (scheme === "light" && width === WIDTHS[0]) {
        report(`login @${width}`, await page.evaluate(audit));
        // the audit must catch a known-bad layout, or every PASS below means nothing
        await page.evaluate(() => {
          const card = document.createElement("div"); card.className = "card"; card.id = "audit-probe"; card.style.width = "120px";
          card.innerHTML = '<div class="chip">x<span class="badge">carnivore-carnivore</span></div>';
          card.querySelector(".chip").style.width = "60px";
          card.querySelector(".badge").style.whiteSpace = "nowrap";
          document.body.appendChild(card);
        });
        const caught = (await page.evaluate(audit)).some((f) => /spills out of div\.chip/.test(f));
        await page.evaluate(() => document.querySelector("#audit-probe").remove());
        if (caught) console.log("  PASS audit self-check catches a spilling badge"); else { fails++; console.log("  FAIL audit self-check: a spilling badge was not reported"); }
      }
      await page.evaluate((t) => sessionStorage.setItem("isle-token", t), TOKEN);
      await page.reload();
      const nav = async (route) => { await page.evaluate((r) => { location.hash = "#/" + r + (location.hash === "#/" + r ? "?" : ""); }, route); await page.waitForSelector("#content h1"); };
      for (const route of ROUTES) {
        await nav(route);
        await page.waitForSelector("#content h1");
        await settle(page);
        if (route === "settings") await page.evaluate(() => { const d = document.querySelector("details.settings-group"); if (d) d.open = true; });
        report(`${scheme} ${route || "dashboard"} @${width}`, await page.evaluate(audit));
        if (process.env.OVERFLOW_SHOTS && scheme === "light" && (width === 1280 || width === 320)) {
          mkdirSync(process.env.OVERFLOW_SHOTS, { recursive: true });
          await page.screenshot({ path: join(process.env.OVERFLOW_SHOTS, `${route || "dashboard"}-${width}.png`), fullPage: true });
        }
      }
      if (width === 1280 || width === 390) {
        // dialogs and transient UI
        await nav(""); await page.waitForSelector(".list strong"); await settle(page);
        await page.click(".list button:has-text('Output')");
        report(`${scheme} job output dialog @${width}`, await page.evaluate(audit));
        await page.keyboard.press("Escape");
        await page.click(".hero button:has-text('Stop')");
        report(`${scheme} confirm dialog @${width}`, await page.evaluate(audit));
        await page.keyboard.press("Escape");
        await nav("snapshots"); await page.waitForSelector("table button:has-text('Restore')"); await settle(page);
        await page.click("table button:has-text('Restore') >> nth=0");
        report(`${scheme} restore dialog @${width}`, await page.evaluate(audit));
        await page.keyboard.press("Escape");
        await nav("settings"); await page.waitForSelector("#set-MAX_PLAYERS"); await settle(page);
        await page.fill("#set-MAX_PLAYERS", "not-a-number-" + "x".repeat(60));
        await page.click(".sticky-bar button:has-text('Save changes')");
        await page.waitForSelector(".toast.error");
        report(`${scheme} error toast @${width}`, await page.evaluate(audit));
        if (width === 390) {
          await page.click("#menu"); await sleep(300);
          report(`${scheme} phone menu @${width}`, await page.evaluate(audit));
        }
      }
      await ctx.close();
    }
  }
  for (const width of [1280, 390]) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await ctx.newPage();
    await page.goto(BASE + "/docs");
    await page.waitForSelector(".op");
    await page.click("#patchConfig > summary");
    report(`docs @${width}`, await page.evaluate(audit));
    await ctx.close();
  }
} finally {
  await browser.close();
  api.kill();
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* windows lock */ }
}
console.log(`RESULT: ${fails} failure(s)`);
process.exit(fails ? 1 : 0);
