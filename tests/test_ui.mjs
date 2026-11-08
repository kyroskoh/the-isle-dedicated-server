// tests/test_ui.mjs - browser test of the web UI and /docs (PRD UI-01..05).
// Starts tools/isle_api.py with the fake launcher, then drives Chromium with Playwright:
// sign-in, every page, light/dark/system themes, actions, settings, docs "Try it",
// CSP violations and console errors. Screenshots go to $UI_SCREENSHOTS when set.
//   npm i -D playwright@1 && npx playwright install chromium   (if not installed)
//   node tests/test_ui.mjs
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const require = createRequire(import.meta.url);
let pw;
try { pw = require("playwright"); } catch { pw = await import("playwright"); }
// BROWSER=chromium (default) | firefox | webkit - CI runs all three engines
const ENGINE = process.env.BROWSER || "chromium";
const chromium = pw[ENGINE];
if (!chromium) throw new Error("unknown BROWSER " + ENGINE);
const MOBILE = ENGINE !== "firefox";   // Firefox has no isMobile emulation (touch still works)
console.log("## engine: " + ENGINE);

const REPO = dirname(dirname(fileURLToPath(import.meta.url)));
const PY = process.env.PYTHON || (process.platform === "win32" ? "python" : "python3");
const TOKEN = "ui-test-token-0123456789abcdef";
const SHOTS = process.env.UI_SCREENSHOTS || "";
let fails = 0;
async function ck(label, fn) {
  let ok = false;
  try { ok = Boolean(await fn()); } catch (e) { console.log("    error: " + e.message.split("\n")[0]); }
  console.log((ok ? "  PASS " : "  FAIL ") + label);
  if (!ok) fails++;
}
const freePort = () => new Promise((res) => { const s = net.createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => res(p)); }); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// page.waitForFunction evaluates a string in the page, which the UI's CSP (no 'unsafe-eval') blocks; poll instead
async function waitUntil(page, fn, timeout = 10000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (await page.evaluate(fn)) return true; await sleep(100); }
  throw new Error("timed out waiting for " + fn.toString().slice(0, 80));
}

// ------------------------------------------------- date formatting (unit)
{
  console.log("## date formatting");
  const vm = await import("node:vm");
  const store = {};
  const sandbox = { window: {}, localStorage: { getItem: (k) => store[k] || null, setItem: (k, v) => { store[k] = String(v); } }, Date };
  vm.runInNewContext(readFileSync(join(REPO, "ui", "datetime.js"), "utf8"), sandbox);
  const T = sandbox.window.IsleTime;
  const at = "2026-11-08T06:05:07Z";   // 14:05:07 at UTC+08:00
  T.setServer(480, "UTC+08:00");
  await ck("default format uses MMM", () => T.format(at) === "08 Nov 2026, 14:05:07");
  await ck("UTC zone", () => T.format(at, "dd MMM yyyy HH:mm:ss ZZ", "utc") === "08 Nov 2026 06:05:07 UTC");
  await ck("server zone", () => T.format(at, "yyyy-MM-dd HH:mm ZZ", "server") === "2026-11-08 14:05 UTC+08:00");
  await ck("12-hour and weekday", () => T.format(at, "EEE, MMM d, yyyy h:mm:ss a", "server") === "Sun, Nov 8, 2026 2:05:07 PM");
  await ck("full month, literals", () => T.format(at, "d MMMM yyyy 'at' HH'h'", "utc") === "8 November 2026 at 06h");
  await ck("midnight is 12 AM", () => T.format("2026-01-01T00:00:00Z", "hh:mm a", "utc") === "12:00 AM");
  await ck("negative offsets", () => { T.setServer(-300, null); const r = T.format(at, "HH:mm ZZ", "server"); T.setServer(480, "UTC+08:00"); return r === "01:05 UTC-05:00"; });
  await ck("bad input does not throw", () => T.format("not a date") === "not a date" && T.format(null) === "–");
  await ck("choice is remembered", () => { T.setFormat("yyyy-MM-dd"); T.setZone("utc"); return T.getFormat() === "yyyy-MM-dd" && T.getZone() === "utc"; });
}

// ------------------------------------------------------------- API server
const dir = mkdtempSync(join(tmpdir(), "isle-ui-"));
mkdirSync(join(dir, "config"));
const conf = join(dir, "config", "server.conf");
writeFileSync(conf, readFileSync(join(REPO, "config", "server.conf.example"), "utf8")
  .replace(/^RCON_PASSWORD=.*$/m, "RCON_PASSWORD=secret-pw").replace(/^SERVER_NAME=.*$/m, 'SERVER_NAME="Jungle Test"'));
const port = await freePort();
const api = spawn(PY, [join(REPO, "tools", "isle_api.py"), "--conf", conf, "--launcher", join(REPO, "tests", "fixtures", "fake-launcher.py"),
  "--port", String(port), "--snapshot-dir", join(dir, "snapshots")],
  { env: { ...process.env, ISLE_UI_TOKEN: TOKEN, ISLE_LOG_DIR: join(dir, "logs"), FAKE_STATE_DIR: dir, FAKE_LAUNCHER_LOG: join(dir, "calls.log"), FAKE_DELAY: "0.5" }, stdio: ["ignore", "pipe", "pipe"] });
const apiLog = [];
for (const stream of [api.stdout, api.stderr]) stream.on("data", (b) => { apiLog.push(String(b)); if (apiLog.length > 400) apiLog.shift(); });
process.on("uncaughtException", (e) => { console.log("API log (last lines):\n" + apiLog.join("").split("\n").slice(-30).join("\n")); throw e; });
const BASE = `http://127.0.0.1:${port}`;
for (let i = 0; i < 100; i++) { try { if ((await fetch(BASE + "/api/v1/health")).ok) break; } catch { /* starting */ } await sleep(100); }

const browser = await chromium.launch();
const problems = [];
async function newPage(opts = {}) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, deviceScaleFactor: SHOTS ? 2 : 1, ...opts });
  const page = await ctx.newPage();
  page.on("console", (m) => { if (m.type() === "error" && !/401|409|502|Failed to load resource/.test(m.text())) problems.push(m.text()); });
  page.on("pageerror", (e) => problems.push("pageerror: " + e.message));
  return { ctx, page };
}
const shot = async (page, name) => { if (SHOTS) { mkdirSync(SHOTS, { recursive: true }); await page.screenshot({ path: join(SHOTS, name + ".png"), fullPage: false, caret: "initial", animations: "allow" }); } };
const bg = (page) => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
const conf_ = (k) => (readFileSync(conf, "utf8").match(new RegExp("^" + k + "=(.*)$", "m")) || [])[1];

try {
  console.log("## sign-in");
  const { ctx, page } = await newPage({ colorScheme: "light" });
  await page.goto(BASE + "/");
  await ck("login form shown", () => page.isVisible("#login-form"));
  await shot(page, "01-login-light");
  await page.fill("#token", "wrong-token-xxxxxxxxxx");
  await page.click('#login-form button[type="submit"]');
  await ck("wrong token refused", async () => { await page.waitForSelector("#login-error:not([hidden])"); return /not right/.test(await page.textContent("#login-error")); });
  await page.fill("#token", TOKEN);
  await page.click('#login-form button[type="submit"]');
  await ck("dashboard after sign-in", async () => { await page.waitForSelector("h1:text('Dashboard')"); return true; });
  await ck("server name in the top bar", async () => { await waitUntil(page, () => document.querySelector("#server-name").textContent === "Jungle Test"); return true; });
  await ck("token kept in sessionStorage only", () => page.evaluate((t) => sessionStorage.getItem("isle-token") === t && !JSON.stringify(localStorage).includes(t), TOKEN));

  console.log("## themes (light / dark / system)");
  await ck("system theme follows a light OS", async () => (await bg(page)) === "rgb(244, 246, 242)");
  await page.emulateMedia({ colorScheme: "dark" });
  await ck("system theme follows a dark OS live", async () => (await bg(page)) === "rgb(13, 19, 16)");
  await sleep(400);  // let colour transitions finish
  await shot(page, "02-dashboard-dark");
  await page.click('#theme-switch input[value="light"]', { force: true });
  await ck("light overrides a dark OS", async () => (await page.getAttribute("html", "data-theme")) === "light" && (await bg(page)) === "rgb(244, 246, 242)");
  await page.reload();
  await ck("theme choice remembered", async () => (await page.getAttribute("html", "data-theme")) === "light" && await page.isChecked('#theme-switch input[value="light"]'));
  await page.click('#theme-switch input[value="dark"]', { force: true });
  await page.emulateMedia({ colorScheme: "light" });
  await ck("dark overrides a light OS", async () => (await bg(page)) === "rgb(13, 19, 16)");
  await page.click('#theme-switch input[value="system"]', { force: true });
  await ck("system again", async () => (await page.getAttribute("html", "data-theme")) === null && (await bg(page)) === "rgb(244, 246, 242)");
  await shot(page, "03-dashboard-light");

  console.log("## server actions");
  await page.click("button:has-text('Start')");
  await ck("job panel shows progress", async () => { await page.waitForSelector("#jobs-panel:not([hidden]) .progress", { timeout: 3000 }); return true; });
  await ck("start finishes, status Running", async () => { await waitUntil(page, () => document.querySelector("#status-pill").textContent === "Running", 15000); return true; });
  await ck("start listed in recent activity", async () => { await page.click("button:has-text('Refresh')"); await page.waitForSelector(".list strong:text('start')"); return true; });
  await page.click(".hero button:has-text('Stop')");
  await ck("stop asks for confirmation", async () => { await page.waitForSelector("#confirm[open]"); return /disconnected/.test(await page.textContent("#confirm-text")); });
  await shot(page, "04-confirm-stop");
  await page.click("#confirm button[value='cancel']");
  await ck("cancel keeps it running", async () => { await sleep(800); return (await page.textContent("#status-pill")) === "Running"; });

  console.log("## pages");
  const pages = [["settings", "Settings"], ["players", "Players"], ["roster", "Roster"], ["profiles", "Profiles & presets"], ["plugins", "Plugins"],
    ["snapshots", "Snapshots & backups"], ["logs", "Logs"], ["console", "RCON console"]];
  for (const [route, title] of pages) {
    await page.click(`#nav a[href="#/${route}"]`);
    await ck(`${title} page`, async () => {
      await page.waitForSelector(`h1:text("${title}")`);
      await waitUntil(page, () => !document.querySelector("#content [role=status]"), 8000);
      return (await page.getAttribute(`#nav a[href="#/${route}"]`, "aria-current")) === "page";
    });
    await shot(page, `10-${route}`);
  }

  console.log("## settings, players, roster");
  await page.click('#nav a[href="#/settings"]');
  await page.waitForSelector("#set-MAX_PLAYERS");
  await ck("secrets are masked", async () => (await page.inputValue("#set-RCON_PASSWORD")) === "********");
  await ck("machine keys are read-only", () => page.isDisabled("#set-SERVER_DIR"));
  await ck("machine keys collapsed at the end", async () => !(await page.isVisible("#set-SERVER_DIR")));
  await page.fill("#set-MAX_PLAYERS", "64");
  await ck("unsaved change counted", async () => /1 unsaved change/.test(await page.textContent(".sticky-bar")));
  await page.click(".sticky-bar button:has-text('Save changes')");
  await ck("setting saved to server.conf", async () => { await page.waitForSelector(".toast:has-text('Settings saved')"); return conf_("MAX_PLAYERS") === "64" && conf_("RCON_PASSWORD") === "secret-pw"; });
  await page.fill("#set-MAX_PLAYERS", "lots");
  await page.click(".sticky-bar button:has-text('Save changes')");
  await ck("invalid value refused, file unchanged", async () => { await page.waitForSelector(".toast.error"); return conf_("MAX_PLAYERS") === "64"; });
  await page.fill('input[type="search"]', "rcon");
  await ck("settings filter", async () => (await page.isHidden("#set-MAX_PLAYERS")) && (await page.isVisible("#set-RCON_PORT")));

  await page.click('#nav a[href="#/players"]');
  await page.fill('input[aria-label="SteamID64 to add"] >> nth=0', "123");
  await page.click("form.input-group button >> nth=0");
  await ck("bad SteamID64 rejected in the browser", async () => (await page.getAttribute('input[aria-label="SteamID64 to add"] >> nth=0', "aria-invalid")) === "true");
  await page.fill('input[aria-label="SteamID64 to add"] >> nth=0', "76561198000000042");
  await page.click("form.input-group button >> nth=0");
  await ck("admin added", async () => { await page.waitForSelector("code:text('76561198000000042')"); return conf_("ADMIN_STEAM_IDS") === "76561198000000042"; });

  await page.click('#nav a[href="#/roster"]');
  await page.waitForSelector(".chip");
  await page.click("button:has-text('None') >> nth=0");
  await page.click(".chip:has-text('Tyrannosaurus') >> nth=0");
  await page.click(".card-head button:has-text('Save') >> nth=0");
  await ck("roster saved", async () => { await page.waitForSelector(".toast:has-text('Playable roster saved')"); return conf_("ALLOWED_CLASSES") === "Tyrannosaurus"; });

  console.log("## date & time preferences");
  await page.click('#nav a[href="#/"]');
  await page.waitForSelector(".list time");
  await ck("dates show with MMM by default", async () => /^\d{2} [A-Z][a-z]{2} \d{4}, \d{2}:\d{2}:\d{2}$/.test(await page.textContent(".list time")));
  await ck("full timestamp peeks on hover", async () => { await page.hover(".list time"); await page.waitForSelector("#peek:not([hidden])");
    return /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/.test(await page.textContent("#peek")); });
  await page.click("#datetime");
  await page.waitForSelector("#modal[open] #date-format");
  await page.check('input[name="tz"][value="utc"]');
  await page.selectOption("#date-format", "yyyy-MM-dd HH:mm:ss");
  await ck("live preview", async () => /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(await page.textContent("output.preview")));
  await shot(page, "05-date-time-dialog");
  await page.click("#modal button:has-text('Save')");
  await ck("UTC + ISO applied", async () => { await page.waitForSelector(".list time"); return /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(await page.textContent(".list time")); });
  await ck("UTC is really UTC", async () => { const iso = await page.getAttribute(".list time", "datetime"); return (await page.textContent(".list time")) === iso.replace("T", " ").replace("Z", ""); });
  await page.click("#datetime");
  await page.selectOption("#date-format", "custom");
  await page.fill("#date-format-custom", "EEEE d MMMM 'at' HH:mm ZZ");
  await ck("custom pattern preview", async () => / at \d{2}:\d{2} UTC$/.test(await page.textContent("output.preview")));
  await page.click("#modal button:has-text('Save')");
  await page.reload();
  await ck("preferences survive a reload", async () => { await page.waitForSelector(".list time"); return / at \d{2}:\d{2} UTC$/.test(await page.textContent(".list time")); });
  await page.evaluate(() => { localStorage.removeItem("isle-tz"); localStorage.removeItem("isle-datefmt"); });
  await page.reload();
  await page.waitForSelector(".list time");

  console.log("## responsive + docs");
  const mobile = await newPage({ viewport: { width: 390, height: 844 }, colorScheme: "dark", hasTouch: true, isMobile: MOBILE });
  await mobile.page.goto(BASE + "/");
  await mobile.page.evaluate((t) => sessionStorage.setItem("isle-token", t), TOKEN);
  await mobile.page.reload();
  await ck("phone: no horizontal scroll", async () => { await mobile.page.waitForSelector("h1:text('Dashboard')"); return mobile.page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth); });
  await mobile.page.goto(BASE + "/#/roster");
  await mobile.page.waitForSelector(".chip");
  await ck("phone: tap shows cut-off text (touch peek)", async () => {
    const chip = mobile.page.locator(".chip", { hasText: "Pachycephalosaurus" }).first();
    const cut = await chip.locator("span").first().evaluate((e) => e.scrollWidth > e.clientWidth);
    if (!cut) return true;   // not truncated at this width: nothing to peek
    await chip.tap();
    await mobile.page.waitForSelector("#peek:not([hidden])", { timeout: 2000 });
    return (await mobile.page.textContent("#peek")).includes("Pachycephalosaurus");
  });
  await mobile.page.goto(BASE + "/#/");
  await mobile.page.waitForSelector("h1:text('Dashboard')");
  await mobile.page.click("#menu");
  await ck("phone: menu opens", async () => (await mobile.page.getAttribute("#menu", "aria-expanded")) === "true");
  await sleep(400);
  await shot(mobile.page, "20-phone-menu-dark");
  await mobile.page.mouse.click(370, 400);
  await ck("phone: backdrop tap closes the menu", async () => (await mobile.page.getAttribute("#menu", "aria-expanded")) === "false");
  await mobile.ctx.close();

  const docs = await newPage({ colorScheme: "dark" });
  await docs.page.goto(BASE + "/docs", { waitUntil: "domcontentloaded" });
  await ck("docs list every operation", async () => {
    await docs.page.waitForSelector(".op");
    const spec = await (await fetch(BASE + "/openapi.json")).json();
    const n = Object.values(spec.paths).reduce((a, p) => a + Object.keys(p).length, 0);
    return (await docs.page.locator(".op").count()) === n;
  });
  await docs.page.click("#getHealth > summary");
  await docs.page.click("#getHealth button:has-text('Send request')");
  await ck("docs: try it /health", async () => { await docs.page.waitForSelector("#getHealth pre.output:not([hidden]):has-text('HTTP 200')"); return true; });
  await docs.page.click("#getStatus > summary");
  await docs.page.click("#getStatus button:has-text('Send request')");
  await ck("docs: status needs the token", async () => { await docs.page.waitForSelector("#getStatus pre.output:has-text('HTTP 401')"); return true; });
  await docs.page.fill("#docs-token", TOKEN);
  await docs.page.click("#auth-save");
  await docs.page.click("#getStatus button:has-text('Send request')");
  await ck("docs: status with the token", async () => { await docs.page.waitForSelector("#getStatus pre.output:has-text('HTTP 200')"); return true; });
  await docs.page.fill("#op-filter", "snapshot");
  await ck("docs filter", async () => (await docs.page.locator(".op:visible").count()) === 4);
  await docs.page.fill("#op-filter", "");
  await shot(docs.page, "30-docs-dark");
  await docs.ctx.close();

  await page.click("#logout");
  await ck("sign out clears the token", async () => (await page.isVisible("#login-form")) && (await page.evaluate(() => sessionStorage.getItem("isle-token"))) === null);
  await ck("no CSP violations or script errors", () => { if (problems.length) console.log("    " + problems.join("\n    ")); return problems.length === 0; });
  await ctx.close();
} finally {
  await browser.close();
  api.kill();
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* windows lock */ }
}
if (SHOTS && existsSync(SHOTS)) console.log("screenshots: " + SHOTS);
console.log(`RESULT: ${fails} failure(s)`);
process.exit(fails ? 1 : 0);
