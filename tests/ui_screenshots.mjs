// tests/ui_screenshots.mjs - regenerate the documentation screenshots in docs/images/ui/.
// Runs the API against a throw-away server.conf, the fake launcher and an RCON-speaking fake
// game server, seeds realistic state, then captures every page in light and dark.
//   node tests/ui_screenshots.mjs [OUT_DIR]       (needs Playwright + Chromium, like test_ui.mjs)
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require("playwright")); } catch { ({ chromium } = await import("playwright")); }

const REPO = dirname(dirname(fileURLToPath(import.meta.url)));
const OUT = process.argv[2] || join(REPO, "docs", "images", "ui");
const PY = process.env.PYTHON || (process.platform === "win32" ? "python" : "python3");
const TOKEN = "screenshot-token-0123456789abcdef";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => res(p)); }); });

// ------------------------------------------------------------------ state
const dir = mkdtempSync(join(tmpdir(), "isle-shots-"));
mkdirSync(join(dir, "config"));
const portFree = (p) => new Promise((res) => { const s = net.createServer(); s.once("error", () => res(false)); s.listen(p, "127.0.0.1", () => s.close(() => res(true))); });
const rconPort = (await portFree(8888)) ? 8888 : await freePort();
const conf = join(dir, "config", "server.conf");
writeFileSync(conf, readFileSync(join(REPO, "config", "server.conf.example"), "utf8")
  .replace(/^RCON_PASSWORD=.*$/m, "RCON_PASSWORD=docs-secret")
  .replace(/^RCON_PORT=.*$/m, "RCON_PORT=" + rconPort)
  .replace(/^SERVER_NAME=.*$/m, 'SERVER_NAME="Gondwa Survival | Realism"')
  .replace(/^MAX_PLAYERS=.*$/m, "MAX_PLAYERS=100")
  .replace(/^ADMIN_STEAM_IDS=.*$/m, "ADMIN_STEAM_IDS=76561198012345678,76561198087654321")
  .replace(/^WHITELIST_IDS=.*$/m, "WHITELIST_IDS=76561198012345678,76561198011112222,76561198033334444")
  .replace(/^ALLOWED_CLASSES=.*$/m, "ALLOWED_CLASSES=Tyrannosaurus,Carnotaurus,Ceratosaurus,Deinosuchus,Dilophosaurus,Herrerasaurus,Omniraptor,Pteranodon,Troodon,Beipiaosaurus,Gallimimus,Diabloceratops,Dryosaurus,Hypsilophodon,Pachycephalosaurus,Stegosaurus,Tenontosaurus,Maiasaura,Triceratops")
  .replace(/^DISABLED_AI_CLASSES=.*$/m, "DISABLED_AI_CLASSES=Compsognathus"));

// realistic log for the Logs page
const logLines = [];
const t0 = Date.UTC(2026, 10, 8, 18, 0, 0);
const events = ["LogInit: Display: Engine is initialized.", "LogTheIsle: Loading map Gateway", "LogTheIsle: Server listening on 0.0.0.0:7777",
  "LogOnline: EOS session created", "LogTheIsleJoinData: Player joined: RexHunter (76561198011112222)",
  "LogTheIsleJoinData: Player joined: Ptera_Pal (76561198033334444)", "LogTheIsleCharacter: RexHunter spawned as Tyrannosaurus (Juvenile)",
  "LogTheIsleChat: [Global] Ptera_Pal: anyone at the lighthouse?", "LogTheIsleCharacter: Ptera_Pal grew to Adult Pteranodon",
  "LogTheIsle: World saved (12 players, 1832 AI)", "LogTheIsleJoinData: Player left: RexHunter", "LogTheIsle: Rcon: announce \"Restart in 30 minutes\""];
for (let i = 0; i < 120; i++) {
  const ts = new Date(t0 + i * 37000).toISOString().replace("T", "-").replace(/:/g, ".").slice(0, 19);
  logLines.push(`[${ts}:${String(i * 7 % 1000).padStart(3, "0")}][${i % 300}]${events[i % events.length]}`);
}
writeFileSync(join(dir, "server.log"), logLines.join("\n") + "\n");
// rotated logs as the launcher writes them (KIND_yyyymmdd_hhmmss.log)
mkdirSync(join(dir, "logs"));
writeFileSync(join(dir, "logs", "server_20261108_180000.log"), logLines.join("\n") + "\n");
writeFileSync(join(dir, "logs", "server_20261107_180000.log"), logLines.slice(0, 40).join("\n") + "\n");
writeFileSync(join(dir, "logs", "launcher_20261108_175958.log"), [
  "[2026-11-08 17:59:58 UTC+08:00] CMD  start", "[2026-11-08 17:59:58 UTC+08:00] INFO Starting server in the background (logs: /home/theisle/theisle-scripts/logs)",
  "[2026-11-08 17:59:59 UTC+08:00] OK   Wrote Game.ini", "[2026-11-08 18:00:00 UTC+08:00] INFO Launching: TheIsleServer-Linux-Shipping TheIsle -Port=7777 -log",
  "[2026-11-08 18:30:00 UTC+08:00] CMD  backup", "[2026-11-08 18:30:02 UTC+08:00] OK   Backup written (182M)"].join("\n") + "\n");

// fake game server answering RCON
const srv = join(dir, "srv");
mkdirSync(join(srv, "TheIsle", "Saved", "Config", "LinuxServer"), { recursive: true });
writeFileSync(join(srv, "TheIsle", "Saved", "Config", "LinuxServer", "Game.ini"),
  `[/Script/TheIsle.TIGameSession]\nbRconEnabled=true\nRconPassword=docs-secret\nRconPort=${rconPort}\n`);
const game = spawn(PY, [join(REPO, "tests", "fixtures", "fake-isle-server.py")], { cwd: srv, stdio: "ignore" });

const port = await freePort();
const env = { ...process.env, ISLE_UI_TOKEN: TOKEN, ISLE_LOG_DIR: join(dir, "logs"), FAKE_STATE_DIR: dir, FAKE_LAUNCHER_LOG: join(dir, "calls.log"),
  FAKE_DELAY: "0.2", FAKE_LOG_FILE: join(dir, "server.log") };
const api = spawn(PY, [join(REPO, "tools", "isle_api.py"), "--conf", conf, "--launcher", join(REPO, "tests", "fixtures", "fake-launcher.py"),
  "--port", String(port), "--snapshot-dir", join(dir, "snapshots")], { env, stdio: "ignore" });
const BASE = `http://127.0.0.1:${port}`;
for (let i = 0; i < 100; i++) { try { if ((await fetch(BASE + "/api/v1/health")).ok) break; } catch { /* starting */ } await sleep(100); }

const call = async (method, path, body) => {
  const r = await fetch(BASE + "/api/v1" + path, { method, headers: { Authorization: "Bearer " + TOKEN, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined });
  return r.status === 204 ? null : r.json();
};
const waitJob = async (job) => { for (let i = 0; i < 100; i++) { const j = await call("GET", "/jobs/" + job.id); if (j.state !== "running") return j; await sleep(100); } };
await waitJob(await call("POST", "/server/backup"));
await waitJob(await call("POST", "/snapshots", { include: ["worlds", "settings", "overrides", "plugins"] }));
await waitJob(await call("POST", "/server/start"));
await waitJob(await call("POST", "/server/save"));

// ---------------------------------------------------------------- capture
mkdirSync(OUT, { recursive: true });
const browser = await chromium.launch();
const made = [];
async function session(scheme, viewport = { width: 1280, height: 800 }, touch = false) {
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 2, colorScheme: scheme, reducedMotion: "reduce", hasTouch: touch, isMobile: touch });
  const page = await ctx.newPage();
  await page.goto(BASE + "/");
  await page.evaluate((t) => sessionStorage.setItem("isle-token", t), TOKEN);
  await page.reload();
  await page.waitForSelector("#content h1");
  return { ctx, page };
}
async function settle(page) {
  for (let i = 0; i < 80; i++) { if (await page.evaluate(() => !document.querySelector("#content [role=status]"))) break; await sleep(100); }
  await page.evaluate(() => { if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur(); document.querySelectorAll(".toast").forEach((t) => t.remove()); const p = document.querySelector("#jobs-panel"); if (p) p.hidden = true; });
  await sleep(250);
}
async function snap(page, name, opts = {}) {
  await settle(page);
  const file = join(OUT, name + ".png");
  await page.screenshot({ path: file, fullPage: !!opts.full, caret: "initial", animations: "allow" });  // no injected <style> (CSP)
  made.push(file);
}
async function go(page, route) { await page.click(`#nav a[href="#/${route}"]`); await page.waitForSelector("#content h1"); await settle(page); }

try {
  // sign-in page
  const login = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2, colorScheme: "light" });
  const lp = await login.newPage();
  await lp.goto(BASE + "/");
  await lp.waitForSelector("#login-form");
  await snap(lp, "login");
  await login.close();

  for (const scheme of ["light", "dark"]) {
    const { ctx, page } = await session(scheme);
    await settle(page);
    await page.waitForSelector(".list strong");
    await snap(page, `dashboard-${scheme}`);
    if (scheme === "dark") { await go(page, "settings"); await snap(page, "settings-dark"); await ctx.close(); continue; }

    await go(page, "settings");
    await page.fill("#set-MAX_PLAYERS", "120");
    await page.evaluate(() => { const g = document.querySelector("#set-MAX_PLAYERS").closest(".settings-group"); window.scrollTo(0, g.getBoundingClientRect().top + window.scrollY - 90); });
    await snap(page, "settings");
    await go(page, "players"); await snap(page, "players");
    await go(page, "roster"); await snap(page, "roster");
    await go(page, "profiles"); await snap(page, "profiles");
    await go(page, "plugins"); await snap(page, "plugins");
    await go(page, "snapshots"); await snap(page, "snapshots");
    await page.click("table button:has-text('Restore')");
    await page.waitForSelector("#confirm[open]");
    await snap(page, "snapshot-restore");
    await page.click("#confirm button[value='cancel']");
    await go(page, "logs");
    await page.waitForSelector("#log-source option[value='server_20261108_180000.log']", { state: "attached" });
    await page.selectOption("#log-source", "server_20261108_180000.log");
    await sleep(400);
    await snap(page, "logs");
    await page.click("#datetime");
    await page.waitForSelector("#modal[open] #date-format");
    await snap(page, "date-time");
    await page.click("#modal button:has-text('Cancel')");
    await go(page, "console");
    for (const [cmd, arg] of [["announce", "Restart in 30 minutes - find a safe spot!"], ["playerlist", ""], ["save", ""]]) {
      await page.selectOption("#rcon-cmd", cmd);
      await page.fill("#rcon-args", arg);
      await page.click("button:has-text('Send')");
      await sleep(400);
    }
    await page.fill("#rcon-args", "");
    await snap(page, "console");
    await go(page, "");
    await page.click(".hero button:has-text('Restart')");
    await page.waitForSelector("#confirm[open]");
    await snap(page, "confirm-restart");
    await page.click("#confirm button[value='cancel']");
    await ctx.close();
  }

  // phone
  const phone = await session("dark", { width: 390, height: 844 }, true);
  await settle(phone.page);
  await snap(phone.page, "phone-dashboard-dark");
  await phone.page.click("#menu"); await sleep(400);
  await snap(phone.page, "phone-menu-dark");
  await phone.page.keyboard.press("Escape");
  await phone.page.click("#content", { position: { x: 5, y: 5 } }).catch(() => {});
  await sleep(300);
  // instant peek: tap the cut-off server name
  await phone.page.tap("#server-name");
  await phone.page.waitForSelector("#peek:not([hidden])");
  await sleep(100);
  const shotPeek = join(OUT, "phone-peek-dark.png");
  await phone.page.screenshot({ path: shotPeek }); made.push(shotPeek);
  await phone.ctx.close();

  // landscape phone and portrait tablet
  for (const [name, vp] of [["phone-landscape", { width: 844, height: 390 }], ["tablet-portrait", { width: 820, height: 1180 }]]) {
    const s2 = await session("light", vp);
    await settle(s2.page);
    await s2.page.waitForSelector(".list strong");
    await snap(s2.page, name);
    await s2.ctx.close();
  }

  // API docs
  for (const scheme of ["light", "dark"]) {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 2, colorScheme: scheme });
    const page = await ctx.newPage();
    await page.goto(BASE + "/docs");
    await page.evaluate((t) => sessionStorage.setItem("isle-token", t), TOKEN);
    await page.reload();
    await page.waitForSelector(".op");
    if (scheme === "light") { await snap(page, "api-docs"); }
    else {
      await page.click("#getStatus > summary");
      await page.click("#getStatus button:has-text('Send request')");
      await page.waitForSelector("#getStatus pre.output:has-text('HTTP 200')");
      await page.locator("#getStatus").scrollIntoViewIfNeeded();
      await page.evaluate(() => document.querySelector("#getStatus").scrollIntoView({ block: "start" }));
      await snap(page, "api-docs-try-it-dark");
    }
    await ctx.close();
  }
} finally {
  await browser.close();
  api.kill(); game.kill();
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* windows lock */ }
}

// shrink: the UI is flat colour, a 256-colour palette is visually lossless and ~4x smaller
const py = spawnSync(PY, ["-c", `
import sys
from PIL import Image
for f in sys.argv[1:]:
    im = Image.open(f).convert("RGB")
    im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(f, optimize=True)
`, ...made], { stdio: "inherit" });
if (py.status !== 0) console.log("(PIL not available - screenshots left unoptimised)");
console.log(made.map((f) => f.replace(REPO + "/", "")).join("\n"));
