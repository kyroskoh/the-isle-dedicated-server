/* The Isle server web UI (PRD UI-01/02). Vanilla JS, no external assets.
   Every value from the API is inserted with textContent - never as HTML. */
(function () {
  "use strict";

  var TOKEN_KEY = "isle-token";
  var state = { token: null, status: null, cleanup: null, rconCommands: [] };
  var $ = function (sel, root) { return (root || document).querySelector(sel); };

  // ------------------------------------------------------------ DOM helpers
  function h(tag, attrs) {
    var el = document.createElement(tag);
    attrs = attrs || {};
    Object.keys(attrs).forEach(function (k) {
      var v = attrs[k];
      if (v === null || v === undefined || v === false) return;
      if (k === "text") el.textContent = v;
      else if (k === "class") el.className = v;
      else if (k === "on") Object.keys(v).forEach(function (ev) { el.addEventListener(ev, v[ev]); });
      else if (k === "value") el.value = v;
      else if (k === "checked" || k === "disabled" || k === "selected") el[k] = !!v;
      else el.setAttribute(k, v === true ? "" : v);
    });
    for (var i = 2; i < arguments.length; i++) add(el, arguments[i]);
    return el;
  }
  function add(el, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach(function (c) { add(el, c); }); return; }
    el.appendChild(typeof child === "string" || typeof child === "number" ? document.createTextNode(String(child)) : child);
  }
  function icon(name) {
    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("aria-hidden", "true");
    var use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", "#i-" + name);
    svg.appendChild(use);
    return svg;
  }
  function clear(el) { while (el.firstChild) el.removeChild(el.firstChild); return el; }
  function btn(label, opts) {
    opts = opts || {};
    return h("button", { type: opts.type || "button", class: "btn " + (opts.kind || ""), on: opts.onclick ? { click: opts.onclick } : null,
      "aria-label": opts.aria, title: opts.title, disabled: opts.disabled }, opts.icon ? icon(opts.icon) : null, label);
  }
  function busy(button, promise) {
    button.setAttribute("aria-busy", "true"); button.disabled = true;
    return Promise.resolve(promise).finally(function () { button.removeAttribute("aria-busy"); button.disabled = false; });
  }
  function humanize(key) {
    var s = key.toLowerCase().replace(/_/g, " ")
      .replace(/\b(ai|ip|id|ids|rcon|eos|ini|ui|tls|url|puid|pgid|api)\b/g, function (w) { return w.toUpperCase(); });
    return s.charAt(0).toUpperCase() + s.slice(1);
  }
  function fmtBytes(n) {
    if (n < 1024) return n + " B";
    var u = ["KB", "MB", "GB", "TB"], i = -1;
    do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
    return n.toFixed(n < 10 ? 1 : 0) + " " + u[i];
  }
  /* text with break opportunities after "/" and "\\" so paths wrap at folder boundaries, not inside names */
  function breakable(text) {
    var out = [], s = String(text), start = 0;   // no regex lookbehind: older Safari cannot parse it
    for (var i = 0; i < s.length; i++) {
      if (s[i] === "/" || s[i] === "\\") { out.push(s.slice(start, i + 1), document.createElement("wbr")); start = i + 1; }
    }
    out.push(s.slice(start));
    return out;
  }
  function fmtTime(iso) { return window.IsleTime.format(iso); }
  /* <time> in the chosen zone and format; the full timestamp with zone shows instantly on hover/focus/tap */
  function timeEl(iso, cls) {
    return h("time", { datetime: iso || "", class: cls || null, "data-peek": iso ? window.IsleTime.full(iso) : null, tabindex: iso ? "0" : null,
      text: fmtTime(iso) });
  }
  var STEAMID = /^7656119\d{10}$/;

  // ------------------------------------------------------------------- API
  function ApiError(problem) { this.problem = problem; this.message = problem.detail || problem.title; }
  ApiError.prototype = Object.create(Error.prototype);

  function api(method, path, body) {
    var opts = { method: method, headers: { "Authorization": "Bearer " + state.token, "Accept": "application/json" }, cache: "no-store" };
    if (body !== undefined) { opts.headers["Content-Type"] = "application/json"; opts.body = JSON.stringify(body); }
    return fetch("/api/v1" + path, opts).then(function (res) {
      if (res.status === 204) return null;
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (res.ok) return data;
        if (res.status === 401) { signOut("Your session ended - sign in again."); }
        throw new ApiError(data && data.title ? data : { title: "HTTP " + res.status, status: res.status });
      });
    }, function () { throw new ApiError({ title: "Cannot reach the server", detail: "Is the UI service still running?" }); });
  }
  function fail(err, title) {
    var p = err && err.problem ? err.problem : { title: String(err) };
    toast(title || p.title, p.detail && p.detail !== p.title ? p.detail : "", "error");
  }

  // ---------------------------------------------------------------- toasts
  function toast(title, text, kind) {
    var close = btn("", { kind: "ghost sm", icon: "x", aria: "Dismiss" });
    var t = h("div", { class: "toast " + (kind || ""), role: kind === "error" ? "alert" : "status" },
      h("p", null, h("strong", { text: title }), text ? text.slice(0, 600) : null), close);
    var remove = function () { if (t.parentNode) t.parentNode.removeChild(t); };
    close.addEventListener("click", remove);
    $("#toasts").appendChild(t);
    setTimeout(remove, kind === "error" ? 10000 : 5000);
  }

  // --------------------------------------------------------------- dialogs
  function confirmDialog(o) {
    var dlg = $("#confirm");
    $("#confirm-title").textContent = o.title;
    $("#confirm-text").textContent = o.text || "";
    var extra = clear($("#confirm-extra"));
    if (o.extra) add(extra, o.extra);
    var ok = $("#confirm-ok");
    ok.textContent = o.ok || "Confirm";
    ok.className = "btn " + (o.danger ? "danger" : "primary");
    return new Promise(function (resolve) {
      dlg.addEventListener("close", function handler() {
        dlg.removeEventListener("close", handler);
        resolve(dlg.returnValue === "ok");
      });
      dlg.returnValue = "";
      dlg.showModal();
      (o.danger ? dlg.querySelector('button[value="cancel"]') : ok).focus();
    });
  }
  function modal(title, body) {
    var dlg = $("#modal");
    $("#modal-title").textContent = title;
    add(clear($("#modal-body")), body);
    dlg.showModal();
    return dlg;
  }

  // ------------------------------------------------------------------ jobs
  function runJob(label, start) {
    var panel = $("#jobs-panel");
    var out = h("pre", { class: "output", tabindex: "0" });
    var title = h("strong", { text: label + "…" });
    var bar = h("div", { class: "progress", role: "progressbar", "aria-label": label });
    var closeBtn = btn("Close", { kind: "sm", onclick: function () { panel.hidden = true; } });
    closeBtn.hidden = true;
    add(clear(panel), h("div", { class: "card" }, h("div", { class: "card-head" }, title, closeBtn), bar, out));
    panel.hidden = false;
    return start.then(function (job) {
      return new Promise(function (resolve) {
        (function poll() {
          api("GET", "/jobs/" + job.id).then(function (j) {
            out.textContent = j.output.slice(-20000);
            out.scrollTop = out.scrollHeight;
            if (j.state === "running") { setTimeout(poll, 800); return; }
            bar.remove(); closeBtn.hidden = false;
            title.textContent = label + (j.state === "succeeded" ? " - done" : " - failed (exit " + j.exit_code + ")");
            toast(label + (j.state === "succeeded" ? " finished" : " failed"), j.state === "succeeded" ? "" : lastLine(j.output),
              j.state === "succeeded" ? "" : "error");
            if (j.state === "succeeded") setTimeout(function () { if (!closeBtn.hidden) panel.hidden = true; }, 6000);
            refreshStatus();
            resolve(j);
          }, function (e) { setTimeout(poll, 2000); if (e.problem && e.problem.status === 404) { resolve(null); } });
        })();
      });
    }, function (err) { panel.hidden = true; fail(err, label + " was not started"); return null; });
  }
  function lastLine(text) {
    var lines = (text || "").trim().split("\n");
    return lines[lines.length - 1] || "";
  }

  // ----------------------------------------------------------------- status
  function refreshStatus() {
    if (!state.token) return Promise.resolve();
    return api("GET", "/status").then(function (s) {
      state.status = s;
      var pill = $("#status-pill");
      pill.className = "pill " + (s.running ? "ok" : "bad");
      pill.textContent = s.busy_job ? "Working…" : (s.running ? "Running" : "Stopped");
      if (s.busy_job) pill.className = "pill warn";
      $("#server-name").textContent = s.server_name || "The Isle";
      window.IsleTime.setServer(s.utc_offset_minutes, s.zone);
      $("#runtime-badge").textContent = s.runtime === "docker" ? "Docker" : "Native";
      document.dispatchEvent(new CustomEvent("isle-status", { detail: s }));
    }, function (e) {
      var pill = $("#status-pill");
      pill.className = "pill warn"; pill.textContent = "Unknown";
      if (e.problem && e.problem.status !== 401) pill.title = e.message;
    });
  }

  // ----------------------------------------------------------------- pages
  function pageHead(title, sub, actions) {
    return h("div", { class: "page-head" }, h("div", null, h("h1", { text: title }), sub ? h("p", { text: sub }) : null),
      actions ? h("div", { class: "row" }, actions) : null);
  }
  function loading() { return h("p", { class: "muted", role: "status", text: "Loading…" }); }
  function errorCard(err, retry) {
    return h("div", { class: "card", role: "alert" }, h("h2", { text: (err.problem && err.problem.title) || "Something went wrong" }),
      h("p", { class: "muted", text: err.message || "" }), btn("Try again", { icon: "refresh", onclick: retry }));
  }
  function section(c, promise, render) {
    var holder = h("div", null, loading());
    c.appendChild(holder);
    var go = function () {
      clear(holder).appendChild(loading());
      return promise().then(function (data) { clear(holder); render(holder, data, go); },
        function (err) { clear(holder).appendChild(errorCard(err, go)); });
    };
    go();
    return holder;
  }

  var ACTIONS = [
    { id: "start", label: "Start", icon: "play", kind: "primary", when: "stopped" },
    { id: "stop", label: "Stop", icon: "stop", kind: "danger", when: "running", confirm: "Players are disconnected. The world is saved first." },
    { id: "restart", label: "Restart", icon: "refresh", when: "running", confirm: "Players are disconnected for a minute or two." },
    { id: "save", label: "Save world", when: "running" },
    { id: "backup", label: "Back up" }
  ];
  var MAINT = [
    { id: "update", label: "Update game files", confirm: "Downloads the latest server build with SteamCMD. The server must be stopped." },
    { id: "validate", label: "Verify game files", confirm: "Checks every game file and repairs damaged ones. The server must be stopped." }
  ];
  function actionButton(a, after) {
    var b = btn(a.label, { kind: a.kind, icon: a.icon });
    b.dataset.when = a.when || "";
    b.addEventListener("click", function () {
      var go = function () { return runJob(a.label, api("POST", "/server/" + a.id)).then(after); };
      if (!a.confirm) return go();
      confirmDialog({ title: a.label + "?", text: a.confirm, ok: a.label, danger: a.kind === "danger" }).then(function (yes) { if (yes) go(); });
    });
    return b;
  }

  function pageDashboard(c) {
    c.appendChild(pageHead("Dashboard", "Server state, quick actions and recent activity."));
    var dot = h("span", { class: "dot" }), big = h("div", { class: "big", text: "…" }), detail = h("div", { class: "muted small" });
    var buttons = ACTIONS.map(function (a) { return actionButton(a, loadJobs); });
    var hero = h("section", { class: "card hero", "aria-label": "Server state" },
      h("div", { class: "state" }, dot, h("div", null, big, detail)), h("div", { class: "row" }, buttons));
    c.appendChild(hero);
    var paint = function (s) {
      dot.className = "dot" + (s.running ? " on" : "");
      big.textContent = s.running ? "Running" : "Stopped";
      detail.textContent = (s.server_name || "") + " · " + (s.runtime === "docker" ? "Docker" : "Native");
      buttons.forEach(function (b) {
        var w = b.dataset.when;
        b.disabled = !!s.busy_job || (w === "running" && !s.running) || (w === "stopped" && s.running);
      });
    };
    if (state.status) paint(state.status);
    var onStatus = function (e) { paint(e.detail); };
    document.addEventListener("isle-status", onStatus);

    var grid = h("div", { class: "grid cols-2" });
    c.appendChild(h("div", { class: "grid" }, grid));
    var infoCard = h("section", { class: "card" }, h("h2", { text: "Server details" }));
    var jobsCard = h("section", { class: "card" }, h("div", { class: "card-head" }, h("h2", { text: "Recent activity" }),
      btn("Refresh", { kind: "ghost sm", icon: "refresh", onclick: function () { loadJobs(); } })));
    var maintCard = h("section", { class: "card" }, h("h2", { text: "Maintenance" }),
      h("p", { class: "muted small", text: "Stop the server before updating or verifying the game files." }),
      h("div", { class: "row" }, MAINT.map(function (a) { return actionButton(a, loadJobs); })));
    add(grid, [infoCard, jobsCard, maintCard]);
    grid.style.marginTop = "1rem";
    section(infoCard, function () { return api("GET", "/info"); }, function (el, info) {
      var dl = h("dl", { class: "kv" });
      Object.keys(info).forEach(function (k) { add(dl, [h("dt", { text: k }), h("dd", null, breakable(info[k]))]); });
      el.appendChild(Object.keys(info).length ? dl : h("p", { class: "empty", text: "No details" }));
    });
    var jobsHolder = h("div");
    jobsCard.appendChild(jobsHolder);
    function loadJobs() {
      return api("GET", "/jobs").then(function (jobs) {
        clear(jobsHolder);
        if (!jobs.length) { jobsHolder.appendChild(h("p", { class: "empty", text: "Nothing yet - actions you start here appear in this list." })); return; }
        var list = h("ul", { class: "list" });
        jobs.slice(0, 8).forEach(function (j) {
          var badge = h("span", { class: "badge " + (j.state === "succeeded" ? "green" : j.state === "running" ? "amber" : ""), text: j.state });
          add(list, h("li", null, h("span", null, h("strong", { text: j.action }), " ", badge, h("br"), timeEl(j.created, "muted small")),
            btn("Output", { kind: "sm", onclick: function () { modal(j.action + " - " + j.state, h("pre", { class: "output", text: j.output || "(no output)" })); } })));
        });
        jobsHolder.appendChild(list);
      }, function (e) { clear(jobsHolder).appendChild(h("p", { class: "empty", text: e.message })); });
    }
    loadJobs();
    refreshStatus();
    return function () { document.removeEventListener("isle-status", onStatus); };
  }

  function pageSettings(c) {
    var changes = {};
    var count = h("span", { class: "muted", text: "No unsaved changes" });
    var save = btn("Save changes", { kind: "primary", disabled: true });
    var discard = btn("Discard", { disabled: true });
    var filter = h("input", { type: "search", placeholder: "Filter settings…", "aria-label": "Filter settings" });
    c.appendChild(pageHead("Settings", "server.conf - changes are checked before they are saved and apply on the next restart.", [filter]));
    var holder = section(c, function () { return api("GET", "/config"); }, render);
    c.appendChild(h("div", { class: "sticky-bar" }, count, discard, save));

    function mark() {
      var n = Object.keys(changes).length;
      count.textContent = n ? n + " unsaved change" + (n > 1 ? "s" : "") : "No unsaved changes";
      save.disabled = discard.disabled = !n;
    }
    function render(el, data, reload) {
      changes = {}; mark();
      var groups = {}, locked = [];
      data.settings.forEach(function (s) {
        if (!s.editable) locked.push(s); else (groups[s.group] = groups[s.group] || []).push(s);
      });
      Object.keys(groups).forEach(function (g) {
        var fields = h("div", { class: "fields" });
        var card = h("section", { class: "card settings-group" }, h("h2", { text: g }), fields);
        groups[g].forEach(function (s) { fields.appendChild(settingField(s)); });
        el.appendChild(card);
      });
      if (locked.length) {
        var lf = h("div", { class: "fields" });
        locked.forEach(function (s) { lf.appendChild(settingField(s)); });
        el.appendChild(h("details", { class: "card settings-group" },
          h("summary", null, h("strong", { text: "Machine-specific settings (" + locked.length + ")" }), " ",
            h("span", { class: "muted small", text: "paths, runtime and UI address - read-only here, change them with the installer" })), lf));
      }
      discard.onclick = function () { reload(); };
      save.onclick = function () {
        busy(save, api("PATCH", "/config", { values: changes }).then(function (r) {
          toast("Settings saved", r.changed.join(", ") + " - restart the server to apply.");
          reload();
        }, function (e) { fail(e, "Settings were not saved"); }));
      };
      filter.oninput = function () {
        var q = filter.value.trim().toLowerCase();
        el.querySelectorAll(".setting").forEach(function (f) { f.hidden = q && f.dataset.search.indexOf(q) < 0; });
        el.querySelectorAll(".settings-group").forEach(function (g) { g.hidden = !g.querySelector(".setting:not([hidden])"); });
      };
    }
    function settingField(s) {
      var id = "set-" + s.key;
      var wrap = h("div", { class: "field setting" });
      wrap.dataset.search = (s.key + " " + s.description + " " + humanize(s.key)).toLowerCase();
      var track = function (val) {
        if (val === s.value) delete changes[s.key]; else changes[s.key] = val;
        wrap.classList.toggle("changed", val !== s.value); mark();
      };
      var isBool = /^(true|false)$/i.test(s.default) || /^(true|false)$/i.test(s.value);
      var label = h("label", { for: id }, humanize(s.key), " ", h("span", { class: "key", text: s.key }));
      var input;
      if (isBool) {
        input = h("input", { type: "checkbox", id: id, role: "switch", checked: /^true$/i.test(s.value), disabled: !s.editable });
        input.addEventListener("change", function () { track(input.checked ? "true" : "false"); });
        wrap.appendChild(h("div", { class: "row" }, h("label", { class: "switch" }, input, h("span", { class: "track" }), h("span", { text: humanize(s.key) })),
          h("span", { class: "key", text: s.key })));
      } else {
        input = h("input", { type: s.secret ? "password" : "text", id: id, value: s.value, disabled: !s.editable, spellcheck: "false",
          autocomplete: s.secret ? "new-password" : "off", placeholder: s.default ? "default: " + s.default : "" });
        input.addEventListener("input", function () { track(input.value); });
        wrap.appendChild(label);
        if (s.secret) {
          var show = btn("Show", { kind: "sm" });
          show.setAttribute("aria-pressed", "false");
          show.addEventListener("click", function () {
            var on = input.type === "password";
            input.type = on ? "text" : "password"; show.textContent = on ? "Hide" : "Show"; show.setAttribute("aria-pressed", String(on));
          });
          wrap.appendChild(h("div", { class: "input-group" }, input, show));
        } else wrap.appendChild(input);
      }
      var hint = s.description;
      if (s.secret && s.value) hint = "Stored - leave as is to keep it. " + hint;
      if (hint) { var hid = id + "-hint"; input.setAttribute("aria-describedby", hid); wrap.appendChild(h("span", { class: "hint", id: hid, text: hint })); }
      return wrap;
    }
    return function () { return holder; };
  }

  function idListCard(title, sub, path, extra) {
    var card = h("section", { class: "card" }, h("div", { class: "card-head" }, h("h2", { text: title }), extra ? extra.head : null),
      h("p", { class: "muted small", text: sub }));
    var input = h("input", { type: "text", inputmode: "numeric", placeholder: "SteamID64, e.g. 76561198000000000", "aria-label": "SteamID64 to add", spellcheck: "false" });
    var addBtn = btn("Add", { kind: "primary", type: "submit" });
    var form = h("form", { class: "input-group" }, input, addBtn);
    var list = h("div");
    add(card, [form, h("div", { class: "muted small", text: "" }), list]);
    function load() {
      return api("GET", path).then(function (d) {
        if (extra) extra.update(d);
        clear(list);
        if (!d.ids.length) { list.appendChild(h("p", { class: "empty", text: "No one yet." })); return; }
        var ul = h("ul", { class: "list" });
        var known = {};
        (d.players || []).forEach(function (p) { known[p.steam_id] = p.name; });
        var nameEls = {};
        d.ids.forEach(function (id) {
          var rm = btn("Remove", { kind: "sm", aria: "Remove " + id });
          var nameEl = h("strong", { class: "steam-name" });
          nameEls[id] = nameEl;
          showName(nameEl, known[id], known[id] ? "done" : "pending");
          rm.addEventListener("click", function () {
            var who = known[id] ? known[id] + " (" + id + ")" : id;
            confirmDialog({ title: "Remove " + who + "?", text: "From " + title.toLowerCase() + ".", ok: "Remove", danger: true }).then(function (yes) {
              if (yes) busy(rm, api("DELETE", path + "/" + id).then(function () { toast("Removed " + who); load(); }, fail));
            });
          });
          add(ul, h("li", null, h("span", { class: "who" }, nameEl, h("code", { class: "small", text: id })), h("span", { class: "row" },
            h("a", { href: "https://steamcommunity.com/profiles/" + id, target: "_blank", rel: "noopener noreferrer", class: "small", text: "Profile" }), rm)));
        });
        list.appendChild(ul);
        var missing = d.ids.filter(function (id) { return !known[id]; });
        if (missing.length) steamNames(missing).then(function (r) {
          r.players.forEach(function (p) { if (nameEls[p.steam_id]) { known[p.steam_id] = p.name; showName(nameEls[p.steam_id], p.name, r.lookup ? "done" : "off"); } });
        }, function () { missing.forEach(function (id) { showName(nameEls[id], null, "error"); }); });
      }, function (e) { clear(list).appendChild(errorCard(e, load)); });
    }
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var ids = input.value.split(/[\s,]+/).filter(Boolean);
      var bad = ids.filter(function (i) { return !STEAMID.test(i); });
      if (!ids.length || bad.length) { input.setAttribute("aria-invalid", "true"); toast("Not a SteamID64", (bad[0] || "") + " - 17 digits starting with 7656119", "error"); input.focus(); return; }
      input.removeAttribute("aria-invalid");
      busy(addBtn, api("POST", path, { ids: ids }).then(function () {
        input.value = "";
        load();
        return steamNames(ids).then(function (r) {
          var named = r.players.map(function (p) { return p.name ? p.name + " (" + p.steam_id + ")" : p.steam_id; });
          toast("Added " + named.join(", "), r.players.some(function (p) { return !p.name; }) ? "Steam did not return a name (private profile, or lookups are off)." : "");
        }, function () { toast("Added " + ids.join(", ")); });
      }, fail));
    });
    load();
    return card;
  }

  /* Steam names: the API looks them up on Steam (cached on the server); the browser never calls Steam itself */
  function steamNames(ids) { return api("GET", "/steam/names?ids=" + encodeURIComponent(ids.join(","))); }
  function showName(el, name, stateName) {
    el.classList.toggle("muted", !name);
    el.textContent = name || { pending: "Looking up Steam name…", off: "Name lookups off", error: "Name unavailable", done: "Name unknown" }[stateName];
    if (name) el.setAttribute("data-peek", name); else el.removeAttribute("data-peek");
    el.title = name ? "" : (stateName === "done" ? "Private profile, or no Steam account with this ID" : stateName === "off" ? "STEAM_NAME_LOOKUP=false in Settings" : "");
  }

  function pagePlayers(c) {
    c.appendChild(pageHead("Players", "Admins and the whitelist. Changes apply live over RCON when the server is running, otherwise on the next start."));
    var sw = h("input", { type: "checkbox", role: "switch", id: "wl-on" });
    var wlHead = h("label", { class: "switch" }, sw, h("span", { class: "track" }), h("span", { text: "Enabled" }));
    sw.addEventListener("change", function () {
      sw.disabled = true;
      api("PUT", "/whitelist/enabled", { enabled: sw.checked }).then(function () { toast("Whitelist " + (sw.checked ? "on" : "off")); },
        function (e) { sw.checked = !sw.checked; fail(e); }).finally(function () { sw.disabled = false; });
    });
    add(c, h("div", { class: "grid cols-2" },
      idListCard("Admins", "Admins can use admin commands in game.", "/admins"),
      idListCard("Whitelist", "Only whitelisted players can join while it is enabled.", "/whitelist",
        { head: wlHead, update: function (d) { sw.checked = d.enabled; } })));
  }

  var TYPE_ORDER = ["carnivore", "herbivore", "omnivore", "flying", "aquatic", "predator", "prey", "scavenger"];
  var EXTRA_TYPES = {
    human: { label: "human", peek: "Humans are not a dinosaur class: one switch (ENABLE_HUMANS) turns them on or off, live over RCON while the server runs." },
    egg: { label: "egg", peek: "Eggs and hatchlings are not a class and the server has no setting for them: nesting is part of each species' life cycle in game." }
  };
  function classPicker(title, sub, path, allMeansEmpty, presets, extras) {
    var card = h("section", { class: "card" });
    section(card, function () { return api("GET", path); }, function (el, d, reload) {
      var chosen = {};
      var all = d.classes.length === 0 && allMeansEmpty;
      d.known.forEach(function (k) { chosen[k.name] = all || d.classes.indexOf(k.name) >= 0; });
      var summary = h("span", { class: "muted small" });
      var grid = h("div", { class: "chips", role: "group", "aria-label": title });
      var paint = function () {
        var n = Object.keys(chosen).filter(function (k) { return chosen[k]; }).length;
        summary.textContent = allMeansEmpty ? (n === d.known.length ? "All " + n + " classes playable" : n + " of " + d.known.length + " playable")
          : (n ? n + " AI classes disabled" : "No AI classes disabled");
      };
      d.known.forEach(function (k) {
        var cb = h("input", { type: "checkbox", checked: chosen[k.name], "data-name": k.name });
        cb.addEventListener("change", function () { chosen[k.name] = cb.checked; cb.parentNode.classList.toggle("checked", cb.checked); paint(); });
        var types = k.types && k.types.length ? k.types : (k.diet ? [k.diet] : []);
        grid.appendChild(h("label", { class: "chip" + (chosen[k.name] ? " checked" : ""), "data-types": " " + types.join(" ") + " " }, cb, h("span", { text: k.name }),
          types.length ? h("span", { class: "badges" }, types.map(function (t) {
            return h("span", { class: "badge diet " + ({ carnivore: "amber", predator: "amber", herbivore: "green", prey: "green" }[t] || ""), text: t });
          })) : null));
      });
      // humans and eggs are not classes: a live switch, and a note
      var humanSw = null;
      if (extras) {
        humanSw = h("input", { type: "checkbox", role: "switch", checked: !!d.humans, id: "humans-switch" });
        humanSw.addEventListener("change", function () {
          humanSw.disabled = true;
          api("PUT", "/humans", { enabled: humanSw.checked }).then(function () {
            humanSw.parentNode.classList.toggle("checked", humanSw.checked);
            toast("Humans " + (humanSw.checked ? "on" : "off"), "Applied live if the server is running, otherwise on the next start.");
          }, function (e) { humanSw.checked = !humanSw.checked; fail(e); }).finally(function () { humanSw.disabled = false; });
        });
        grid.appendChild(h("label", { class: "chip special" + (d.humans ? " checked" : ""), "data-types": " human ", "data-peek": EXTRA_TYPES.human.peek },
          humanSw, h("span", { text: "Humans" }), h("span", { class: "badges" }, h("span", { class: "badge", text: "human" }))));
        grid.appendChild(h("div", { class: "chip special disabled", "data-types": " egg ", "data-peek": EXTRA_TYPES.egg.peek, tabindex: "0" },
          h("span", { text: "Eggs & hatchlings" }), h("span", { class: "badges" }, h("span", { class: "badge", text: "no setting" }))));
      }
      var boxes = function (type) {
        return Array.prototype.filter.call(grid.querySelectorAll("input[data-name]"), function (cb) {
          return !type || cb.parentNode.getAttribute("data-types").indexOf(" " + type + " ") >= 0;
        });
      };
      var tick = function (cb, v) { cb.checked = v; cb.parentNode.classList.toggle("checked", v); chosen[cb.getAttribute("data-name")] = v; };
      var setAll = function (v) { boxes().forEach(function (cb) { tick(cb, v); }); paint(); };
      // type filter: shows one type, and Only / Add / Remove tick that type in one go (saved with Save)
      var types = [];
      d.known.forEach(function (k) { (k.types || []).forEach(function (t) { if (types.indexOf(t) < 0) types.push(t); }); });
      types.sort(function (a, b) { var ia = TYPE_ORDER.indexOf(a), ib = TYPE_ORDER.indexOf(b); return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || (a < b ? -1 : 1); });
      if (extras) types = types.concat(["human", "egg"]);
      var filterBar = null;
      if (types.length > 1) {
        var current = "";
        var typeActions = h("div", { class: "row type-actions", hidden: true });
        var onlyB = btn("Only", { kind: "sm" }), addB = btn("Add", { kind: "sm" }), remB = btn("Remove", { kind: "sm" });
        onlyB.addEventListener("click", function () { boxes().forEach(function (cb) { tick(cb, boxes(current).indexOf(cb) >= 0); }); paint(); toast("Only " + current + " ticked", "Save to apply."); });
        addB.addEventListener("click", function () { boxes(current).forEach(function (cb) { tick(cb, true); }); paint(); });
        remB.addEventListener("click", function () { boxes(current).forEach(function (cb) { tick(cb, false); }); paint(); });
        var actionLabel = h("span", { class: "muted small" });
        add(typeActions, [actionLabel, onlyB, addB, remB]);
        var filters = h("div", { class: "filters", role: "group", "aria-label": "Filter by type" });
        var setFilter = function (t) {
          current = t;
          filters.querySelectorAll("button").forEach(function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-type") === t)); });
          grid.querySelectorAll(".chip").forEach(function (chip) { chip.hidden = !!t && chip.getAttribute("data-types").indexOf(" " + t + " ") < 0; });
          var real = t && !EXTRA_TYPES[t];
          typeActions.hidden = !real;
          if (real) actionLabel.textContent = boxes(t).length + " " + t + ":";
        };
        [""].concat(types).forEach(function (t) {
          var b = h("button", { type: "button", class: "filter-btn", "data-type": t, "aria-pressed": "false", text: t || "all types" });
          if (EXTRA_TYPES[t]) b.setAttribute("data-peek", EXTRA_TYPES[t].peek);
          b.addEventListener("click", function () { setFilter(current === t ? "" : t); });
          filters.appendChild(b);
        });
        filterBar = h("div", { class: "stack filter-bar" }, filters, typeActions);
        setFilter("");
      }
      var saveBtn = btn("Save", { kind: "primary" });
      saveBtn.addEventListener("click", function () {
        var names = d.known.map(function (k) { return k.name; }).filter(function (n) { return chosen[n]; });
        if (allMeansEmpty && names.length === d.known.length) names = [];
        if (allMeansEmpty && !names.length && d.known.length && Object.keys(chosen).every(function (k) { return !chosen[k]; })) {
          toast("Pick at least one class", "An empty roster would mean every class is playable.", "warn"); return;
        }
        busy(saveBtn, api("PUT", path, { classes: names }).then(function () { toast(title + " saved"); reload(); }, fail));
      });
      var head = h("div", { class: "card-head" }, h("div", null, h("h2", { text: title }), summary),
        h("div", { class: "row" }, btn("All", { kind: "sm", onclick: function () { setAll(true); } }), btn("None", { kind: "sm", onclick: function () { setAll(false); } }), saveBtn));
      add(el, [head, h("p", { class: "muted small", text: sub })]);
      if (presets) el.appendChild(presets(reload));
      if (filterBar) el.appendChild(filterBar);
      el.appendChild(d.known.length ? grid : h("p", { class: "empty", text: "No classes listed in config/classes.txt" }));
      paint();
    });
    return card;
  }

  function pageRoster(c) {
    c.appendChild(pageHead("Roster", "Which dinosaurs players can pick, and which AI creatures are switched off."));
    var presetRow = function (reload) {
      var wrap = h("div", { class: "stack" });
      var row = h("form", { class: "row" });
      // options show only the preset name - Safari sizes a select to its longest option and will not shrink it
      var sel = h("select", { "aria-label": "Roster preset", id: "roster-preset", class: "grow", "aria-describedby": "roster-preset-hint" },
        h("option", { value: "", text: "Loading presets…" }));
      var hint = h("span", { class: "hint", id: "roster-preset-hint" });
      var apply = btn("Apply preset", { type: "submit" });
      add(row, [h("label", { text: "Preset", class: "small", for: "roster-preset" }), sel, apply]);
      add(wrap, [row, hint]);
      wrap.style.marginBottom = ".75rem";
      var described = {};
      var showHint = function () { hint.textContent = described[sel.value] || ""; };
      api("GET", "/rosters").then(function (rs) {
        clear(sel);
        rs.forEach(function (r) { described[r.name] = r.description; sel.appendChild(h("option", { value: r.name, text: r.name })); });
        showHint();
      }, fail);
      sel.addEventListener("change", showHint);
      row.addEventListener("submit", function (ev) {
        ev.preventDefault();
        if (!sel.value) return;
        busy(apply, api("POST", "/classes/preset", { name: sel.value }).then(function () { toast("Roster preset " + sel.value + " applied"); reload(); }, fail));
      });
      return wrap;
    };
    add(c, h("div", { class: "grid" },
      classPicker("Playable roster", "Ticked classes can be chosen. All ticked = every class. Filter by type to tick only carnivores, flyers, ...", "/classes", true, presetRow, true),
      h("p", { class: "muted small" }, "AI creatures (spawning, density, disabled classes) are on the ", h("a", { href: "#/world", text: "Map & AI" }), " page.")));
  }

  function overlayCard(o, onApply, selectable) {
    var keys = Object.keys(o.settings);
    var dl = h("dl", { class: "kv small" });
    keys.slice(0, 8).forEach(function (k) { add(dl, [h("dt", { text: humanize(k) }), h("dd", { text: o.settings[k] })]); });
    var head = h("div", { class: "card-head" }, h("h3", { text: o.name }), selectable || null);
    return h("article", { class: "card stack" }, head, o.description ? h("p", { class: "muted small", text: o.description }) : null, dl,
      keys.length > 8 ? h("span", { class: "muted small", text: "+ " + (keys.length - 8) + " more settings" }) : null, onApply);
  }

  function pageProfiles(c) {
    c.appendChild(pageHead("Profiles & presets", "A profile sets the overall play style. Presets are small add-ons applied on top, left to right."));
    c.appendChild(h("h2", { text: "Profiles" }));
    var profiles = section(c, function () { return api("GET", "/profiles"); }, function (el, list) {
      var grid = h("div", { class: "grid cols-3" });
      list.forEach(function (p) {
        var b = btn("Apply " + p.name, { kind: "primary" });
        b.addEventListener("click", function () {
          confirmDialog({ title: "Apply the " + p.name + " profile?", text: "It changes " + Object.keys(p.settings).length + " settings in server.conf (checked before saving). Restart the server to use them.", ok: "Apply" })
            .then(function (yes) { if (yes) busy(b, api("POST", "/profiles/" + encodeURIComponent(p.name) + "/apply").then(function () { toast("Profile " + p.name + " applied", "Restart the server to use it."); }, fail)); });
        });
        grid.appendChild(overlayCard(p, h("div", { class: "row" }, b)));
      });
      el.appendChild(list.length ? grid : h("p", { class: "empty", text: "No profiles" }));
    });
    profiles.style.marginBottom = "1.5rem";
    var order = [];
    var applyBtn = btn("Apply selected", { kind: "primary", disabled: true });
    var orderText = h("span", { class: "muted small", text: "Select presets below" });
    c.appendChild(h("div", { class: "page-head" }, h("h2", { text: "Presets" }), h("div", { class: "row" }, orderText, applyBtn)));
    section(c, function () { return api("GET", "/presets"); }, function (el, list) {
      var grid = h("div", { class: "grid cols-3" });
      list.forEach(function (p) {
        var cb = h("input", { type: "checkbox", "aria-label": "Select " + p.name });
        cb.addEventListener("change", function () {
          order = order.filter(function (n) { return n !== p.name; });
          if (cb.checked) order.push(p.name);
          applyBtn.disabled = !order.length;
          orderText.textContent = order.length ? "Order: " + order.join(" → ") : "Select presets below";
        });
        grid.appendChild(overlayCard(p, null, h("label", { class: "check" }, cb, "Select")));
      });
      el.appendChild(list.length ? grid : h("p", { class: "empty", text: "No presets" }));
    });
    applyBtn.addEventListener("click", function () {
      confirmDialog({ title: "Apply " + order.length + " preset(s)?", text: order.join(" → "), ok: "Apply" }).then(function (yes) {
        if (yes) busy(applyBtn, api("POST", "/presets/apply", { names: order }).then(function () { toast("Presets applied", order.join(", ")); }, fail));
      });
    });
  }

  function pagePlugins(c) {
    var filter = h("input", { type: "search", placeholder: "Search plugins…", "aria-label": "Search plugins" });
    c.appendChild(pageHead("Plugins", "Install, enable and configure plugins. Plugins run with the server user's rights - only install ones you trust.", [filter]));
    section(c, function () { return api("GET", "/plugins"); }, function (el, d, reload) {
      var presets = h("div", { class: "row" });
      Object.keys(d.presets).sort().forEach(function (name) {
        var b = btn(name, { kind: "sm", title: d.presets[name].join(", ") });
        b.addEventListener("click", function () {
          confirmDialog({ title: "Install the " + name + " preset?", text: "Installs and enables: " + d.presets[name].join(", "), ok: "Install" }).then(function (yes) {
            if (yes) busy(b, api("POST", "/plugins/presets/" + encodeURIComponent(name)).then(function () { toast("Preset " + name + " installed"); reload(); }, fail));
          });
        });
        presets.appendChild(b);
      });
      el.appendChild(h("section", { class: "card" }, h("h2", { text: "Presets" }), presets));
      el.appendChild(h("div", { class: "grid cols-2 gap-top" }, sourcesCard(reload), communityCard()));
      var tbody = h("tbody");
      d.plugins.forEach(function (p) {
        var actions = h("td", { class: "actions", "data-label": "Actions" });
        var act = function (op, label, kind, confirmText) {
          var b = btn(label, { kind: "sm " + (kind || ""), aria: label + " " + p.name });
          b.addEventListener("click", function () {
            var go = function () { busy(b, api("POST", "/plugins/" + encodeURIComponent(p.name) + "/" + op).then(function () { toast(p.name + ": " + label.toLowerCase() + " done"); reload(); }, fail)); };
            if (!confirmText) return go();
            confirmDialog({ title: label + " " + p.name + "?", text: confirmText, ok: label, danger: op === "remove" }).then(function (yes) { if (yes) go(); });
          });
          actions.appendChild(b);
        };
        if (!p.installed) act("install", "Install", "primary", "Plugins run with the server user's rights. Install " + p.name + "?");
        else {
          if (p.enabled) act("disable", "Disable"); else act("enable", "Enable", "primary");
          var cfg = btn("Configure", { kind: "sm" });
          cfg.addEventListener("click", function () { configurePlugin(p.name, reload); });
          actions.appendChild(cfg);
          act("update", "Update");
          act("remove", "Remove", "danger", "Its code is removed; its settings are kept.");
        }
        var tr = h("tr", null,
          h("td", { class: "data", "data-label": "Plugin" }, h("strong", { text: p.name }), h("br"), h("span", { class: "muted small", text: p.description })),
          h("td", { "data-label": "Version", text: p.version || "–" }),
          h("td", { "data-label": "Source" }, h("span", { class: "badge", text: p.source })),
          h("td", { "data-label": "State" }, p.installed ? h("span", { class: "badge " + (p.enabled ? "green" : ""), text: p.enabled ? "enabled" : "installed" }) : h("span", { class: "muted small", text: "available" })),
          actions);
        tr.dataset.search = (p.name + " " + p.description + " " + (p.tags || []).join(" ")).toLowerCase();
        tbody.appendChild(tr);
      });
      var table = h("table", null, h("caption", { class: "sr-only", text: "Plugins" }),
        h("thead", null, h("tr", null, ["Plugin", "Version", "Source", "State"].map(function (t) { return h("th", { scope: "col", text: t }); }), h("th", { scope: "col" }, h("span", { class: "sr-only", text: "Actions" })))), tbody);
      var card = h("section", { class: "card" }, h("div", { class: "table-wrap" }, table));
      card.style.marginTop = "1rem";
      el.appendChild(card);
      filter.oninput = function () {
        var q = filter.value.trim().toLowerCase();
        tbody.querySelectorAll("tr").forEach(function (tr) { tr.hidden = q && tr.dataset.search.indexOf(q) < 0; });
      };
    });
  }

  /* extra plugin catalogs (JSON over HTTPS) */
  function sourcesCard(reloadPlugins) {
    var card = h("section", { class: "card stack" }, h("h2", { text: "Catalog sources" }),
      h("p", { class: "muted small", text: "Add a plugin catalog published by the community (a JSON file over HTTPS, same format as plugins/catalog.json). Its plugins then appear above. Plugins run with the server user's rights - add only catalogs you trust." }));
    var input = h("input", { type: "url", placeholder: "https://example.org/isle-catalog.json", "aria-label": "Catalog URL", spellcheck: "false", autocomplete: "off" });
    var addBtn = btn("Add", { kind: "primary", type: "submit" });
    var list = h("div");
    var form = h("form", { class: "input-group" }, input, addBtn);
    add(card, [form, list]);
    function load() {
      api("GET", "/plugins/sources").then(function (d) {
        clear(list);
        if (!d.sources.length) { list.appendChild(h("p", { class: "empty", text: "No extra catalogs." })); return; }
        var ul = h("ul", { class: "list" });
        d.sources.forEach(function (u) {
          var rm = btn("Remove", { kind: "sm", aria: "Remove " + u });
          rm.addEventListener("click", function () {
            confirmDialog({ title: "Remove this catalog?", text: u, ok: "Remove", danger: true }).then(function (yes) {
              if (yes) busy(rm, api("DELETE", "/plugins/sources?url=" + encodeURIComponent(u)).then(function () { toast("Catalog removed"); load(); reloadPlugins(); }, fail));
            });
          });
          add(ul, h("li", null, h("code", { text: u }), rm));
        });
        list.appendChild(ul);
      }, function (e) { clear(list).appendChild(h("p", { class: "empty", text: e.message })); });
    }
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var u = input.value.trim();
      if (!/^https:\/\/\S+$/.test(u)) { input.setAttribute("aria-invalid", "true"); toast("Use an https:// URL", "", "error"); return; }
      input.removeAttribute("aria-invalid");
      confirmDialog({ title: "Add this catalog?", text: u + " - plugins from it run with the server user's rights.", ok: "Add catalog" }).then(function (yes) {
        if (yes) busy(addBtn, api("POST", "/plugins/sources", { url: u }).then(function () { input.value = ""; toast("Catalog added"); load(); reloadPlugins(); }, fail));
      });
    });
    load();
    return card;
  }
  /* community tools, libraries and guides (third-party; links only) */
  function communityCard() {
    var card = h("section", { class: "card stack" }, h("h2", { text: "Community" }));
    api("GET", "/plugins/community").then(function (d) {
      var ul = h("ul", { class: "list" });
      (d.links || []).forEach(function (l) {
        add(ul, h("li", { class: "community" }, h("div", null,
          h("a", { href: l.url, target: "_blank", rel: "noopener noreferrer", text: l.name }), " ",
          h("span", { class: "badge", text: l.kind }), l.language ? h("span", { class: "muted small", text: " · " + l.language }) : null,
          h("br"), h("span", { class: "muted small", text: l.description }))));
      });
      add(card, [h("p", { class: "muted small", text: "Third-party projects - listed, not installed or endorsed. Check what you download." }), ul]);
      if (d.mods) card.appendChild(h("p", { class: "callout small", text: d.mods }));
    }, function (e) { card.appendChild(h("p", { class: "empty", text: e.message })); });
    return card;
  }

  // ----------------------------------------------------------- map & AI
  function pageWorld(c) {
    c.appendChild(pageHead("Map & AI", "Which map the server loads, and how AI creatures spawn. Changes apply on the next restart (AI density also live)."));
    var maps = h("section", { class: "card" });
    c.appendChild(maps);
    section(maps, function () { return api("GET", "/maps"); }, function (el, d, reload) {
      el.appendChild(h("div", { class: "card-head" }, h("h2", { text: "Map" }),
        h("span", { class: "muted small", text: "Steam branch: " + (d.branch || "(public)") })));
      var grid = h("div", { class: "grid cols-2" });
      d.maps.forEach(function (m) {
        var use = btn(m.current ? "Current map" : "Use " + m.name, { kind: m.current ? "" : "primary", disabled: m.current });
        use.addEventListener("click", function () {
          var branchNote = m.branch !== "-" && m.branch !== d.branch ? " It also switches the Steam branch to " + m.branch + ": stop the server and run Verify game files (validate) before starting." : "";
          var archived = m.status === "archived" ? " This is an archived build: no updates or new species." : "";
          confirmDialog({ title: "Switch to " + m.name + "?", text: "The server loads " + m.name + " after a restart." + branchNote + archived, ok: "Switch map" }).then(function (yes) {
            if (yes) busy(use, api("PUT", "/map", { name: m.name }).then(function () { toast("Map set to " + m.name, branchNote ? "Now stop the server and verify game files." : "Restart to load it."); reload(); }, fail));
          });
        });
        grid.appendChild(h("article", { class: "card stack map" + (m.current ? " current" : "") },
          h("div", { class: "card-head" }, h("h3", { text: m.name }),
            h("span", { class: "badge " + (m.status === "current" ? "green" : "amber"), text: m.status })),
          h("p", { class: "muted small", text: m.description }),
          h("dl", { class: "kv small" }, h("dt", { text: "Steam branch" }), h("dd", { text: m.branch })),
          h("div", { class: "row" }, use)));
      });
      el.appendChild(grid);
      el.appendChild(h("p", { class: "muted small", text: "Maps come from config/maps.txt - add a line there when the developers release a new map. Names are case-sensitive." }));
    });

    var ai = h("section", { class: "card" });
    ai.style.marginTop = "1rem";
    c.appendChild(ai);
    section(ai, function () { return api("GET", "/ai"); }, function (el, d, reload) {
      var spawn = h("input", { type: "checkbox", role: "switch", id: "ai-spawn", checked: d.spawn });
      var range = h("input", { type: "range", id: "ai-density-range", min: "0", max: "3", step: "0.1", value: String(d.density), "aria-label": "AI density" });
      var density = h("input", { type: "number", id: "ai-density", min: "0", max: "10", step: "0.1", value: String(d.density) });
      var interval = h("input", { type: "number", id: "ai-interval", min: "1", max: "86400", step: "1", value: String(d.interval) });
      range.addEventListener("input", function () { density.value = range.value; });
      density.addEventListener("input", function () { range.value = density.value; });
      var save = btn("Save AI settings", { kind: "primary" });
      save.addEventListener("click", function () {
        var dv = parseFloat(density.value), iv = parseInt(interval.value, 10);
        if (isNaN(dv) || dv < 0 || dv > 10) { density.setAttribute("aria-invalid", "true"); toast("Density must be 0-10", "", "error"); return; }
        if (isNaN(iv) || iv < 1 || String(iv) !== interval.value.trim()) { interval.setAttribute("aria-invalid", "true"); toast("Interval must be whole seconds", "", "error"); return; }
        density.removeAttribute("aria-invalid"); interval.removeAttribute("aria-invalid");
        busy(save, api("PATCH", "/ai", { spawn: spawn.checked, density: dv, interval: iv }).then(function () {
          toast("AI settings saved", "Density applies now if the server is running; the rest on the next restart."); reload();
        }, fail));
      });
      var presets = h("div", { class: "row" });
      d.presets.forEach(function (p) {
        var b = btn(p.name.replace(/^ai-/, ""), { kind: "sm", title: p.description });
        b.setAttribute("data-peek", p.description || p.name);
        b.addEventListener("click", function () {
          confirmDialog({ title: "Apply " + p.name + "?", text: p.description, ok: "Apply" }).then(function (yes) {
            if (yes) busy(b, api("POST", "/ai/preset", { name: p.name }).then(function () { toast(p.name + " applied"); reload(); }, fail));
          });
        });
        presets.appendChild(b);
      });
      add(el, [
        h("div", { class: "card-head" }, h("h2", { text: "AI creatures" }), h("label", { class: "switch" }, spawn, h("span", { class: "track" }), h("span", { text: "Spawn AI" }))),
        h("div", { class: "grid cols-2" },
          h("div", { class: "field" }, h("label", { for: "ai-density", text: "Density" }), h("div", { class: "input-group" }, range, density),
            h("span", { class: "hint", text: "0.5 = half as many AI, 2 = twice as many. Lower it before turning AI off - carnivores need the food." })),
          h("div", { class: "field" }, h("label", { for: "ai-interval", text: "Spawn interval (seconds)" }), interval,
            h("span", { class: "hint", text: "How often the server checks to spawn AI (default 40). Lower = AI comes back faster." }))),
        h("div", { class: "row gap-top" }, save),
        h("h3", { class: "gap-top", text: "AI presets" }), presets]);
    });
    var dis = classPicker("Disabled AI", "Ticked AI creatures do not spawn (role in the badge).", "/ai-classes", false);
    dis.style.marginTop = "1rem";
    c.appendChild(dis);
    var mut = mutationsCard();
    mut.style.marginTop = "1rem";
    c.appendChild(mut);
  }

  function mutationsCard() {
    var card = h("section", { class: "card", id: "mutations" });
    section(card, function () { return api("GET", "/mutations"); }, function (el, d, reload) {
      var mode = d.mode;
      var allR = h("input", { type: "radio", name: "mut-mode", value: "all", checked: mode === "all" });
      var customR = h("input", { type: "radio", name: "mut-mode", value: "custom", checked: mode === "custom" });
      var search = h("input", { type: "search", placeholder: "Filter mutations", "aria-label": "Filter mutations", spellcheck: "false" });
      var list = h("div", { class: "mutations" });
      var summary = h("span", { class: "muted small" });
      var rows = d.mutations.map(function (m) {
        var id = "mut-" + m.name.replace(/[^A-Za-z0-9]/g, "");
        var cb = h("input", { type: "checkbox", checked: m.enabled, id: id, "data-name": m.name });
        var val = h("input", { type: "number", min: "0", step: "0.05", value: m.enabled ? m.value : m["default"], readonly: m.fixed ? "readonly" : null,
          "aria-label": m.name + " value", class: "num" });
        if (m.fixed) val.title = "Only 1 works for this mutation";
        var row = h("div", { class: "mut-row" + (m.enabled ? " checked" : ""), "data-name": m.name.toLowerCase() },
          cb, h("label", { for: id, text: m.name, "data-peek": m.name + (m.fixed ? " - on/off only (value 1)" : " - default " + m["default"]) }),
          m.fixed ? h("span", { class: "badge", text: "fixed" }) : null, val);
        cb.addEventListener("change", function () { row.classList.toggle("checked", cb.checked); paint(); });
        return { m: m, cb: cb, val: val, row: row };
      });
      rows.forEach(function (r) { list.appendChild(r.row); });
      var paint = function () {
        var custom = customR.checked;
        list.classList.toggle("locked", !custom);
        rows.forEach(function (r) { r.cb.disabled = !custom; r.val.disabled = !custom; });
        var n = rows.filter(function (r) { return r.cb.checked; }).length;
        summary.textContent = custom ? n + " of " + rows.length + " mutations enabled" : "All " + rows.length + " mutations available (game default)";
      };
      allR.addEventListener("change", paint); customR.addEventListener("change", paint);
      search.addEventListener("input", function () {
        var q = search.value.trim().toLowerCase();
        rows.forEach(function (r) { r.row.hidden = !!q && r.row.getAttribute("data-name").indexOf(q) < 0; });
      });
      var save = btn("Save mutations", { kind: "primary" });
      save.addEventListener("click", function () {
        var body = { mode: customR.checked ? "custom" : "all" };
        if (body.mode === "custom") {
          body.mutations = {};
          var bad = null;
          rows.forEach(function (r) {
            if (!r.cb.checked) return;
            var v = r.val.value.trim();
            if (!/^\d+(\.\d+)?$/.test(v) || (r.m.fixed && v !== "1")) { bad = bad || r; r.val.setAttribute("aria-invalid", "true"); }
            else r.val.removeAttribute("aria-invalid");
            body.mutations[r.m.name] = v;
          });
          if (bad) { toast(bad.m.name + ": " + (bad.m.fixed ? "only 1 works" : "the value must be a number"), "", "error"); bad.val.focus(); return; }
          if (!Object.keys(body.mutations).length) { toast("Tick at least one mutation", "Or choose All mutations.", "warn"); return; }
        }
        busy(save, api("PUT", "/mutations", body).then(function () { toast("Mutations saved", "Applied on the next restart."); reload(); }, fail));
      });
      add(el, [
        h("div", { class: "card-head" }, h("div", null, h("h2", { text: "Mutations" }), summary), save),
        d.enabled_system ? null : h("p", { class: "callout", text: "The mutation system is off (ENABLE_MUTATIONS=false in Settings) - these choices apply once it is on." }),
        h("fieldset", { class: "row plain" }, h("legend", { class: "sr-only", text: "Mutation mode" }),
          h("label", { class: "check" }, allR, "All mutations (game default)"), h("label", { class: "check" }, customR, "Only the ticked ones, with these values")),
        h("p", { class: "muted small", text: "Values other than the default change how strong a mutation is and can unbalance the game. \"fixed\" ones only switch on or off." }),
        search, list]);
      paint();
    });
    return card;
  }

  function configurePlugin(name, after) {
    var body = h("div", { class: "stack" }, loading());
    var dlg = modal("Configure " + name, body);
    api("GET", "/plugins/" + encodeURIComponent(name)).then(function (p) {
      clear(body);
      var values = {};
      var form = h("form", { class: "stack" });
      if (!p.settings.length) form.appendChild(h("p", { class: "empty", text: "This plugin has no settings." }));
      p.settings.forEach(function (s) {
        var id = "pl-" + s.key;
        var input = h("input", { id: id, type: s.secret ? "password" : "text", value: s.value, spellcheck: "false", autocomplete: "off", required: s.required });
        input.addEventListener("input", function () { values[s.key] = input.value; });
        form.appendChild(h("div", { class: "field" }, h("label", { for: id }, s.key, s.required ? " *" : ""), input, s.description ? h("span", { class: "hint", text: s.description }) : null));
      });
      var saveBtn = btn("Save", { kind: "primary", type: "submit", disabled: !p.settings.length });
      form.appendChild(h("div", { class: "actions" }, btn("Close", { onclick: function () { dlg.close(); } }), saveBtn));
      form.addEventListener("submit", function (ev) {
        ev.preventDefault();
        if (!Object.keys(values).length) { dlg.close(); return; }
        busy(saveBtn, api("PATCH", "/plugins/" + encodeURIComponent(name) + "/config", { settings: values }).then(function () { toast(name + " settings saved"); dlg.close(); after(); }, fail));
      });
      var meta = h("dl", { class: "kv" }, h("dt", { text: "Version" }), h("dd", { text: p.version }), h("dt", { text: "Hooks" }), h("dd", { text: p.hooks.join(", ") || "–" }),
        h("dt", { text: "Commands" }), h("dd", { text: p.commands.join(", ") || "–" }));
      add(body, [h("p", { class: "muted", text: p.description }), meta, form]);
      if (p.usage && p.usage.length) body.appendChild(h("pre", { class: "output", text: p.usage.join("\n") }));
    }, function (e) { clear(body).appendChild(errorCard(e, function () { dlg.close(); configurePlugin(name, after); })); });
  }

  var PARTS = [["worlds", "Worlds", true], ["settings", "Settings", true], ["overrides", "Ini overrides", true], ["plugins", "Plugins", true], ["backups", "Backup archives", false]];
  function partChecks(defaults) {
    var box = h("fieldset", { class: "row" }, h("legend", { class: "sr-only", text: "Parts" }));
    box.style.border = "0"; box.style.padding = "0"; box.style.margin = "0";
    PARTS.forEach(function (p) { box.appendChild(h("label", { class: "check" }, h("input", { type: "checkbox", value: p[0], checked: defaults ? defaults.indexOf(p[0]) >= 0 : p[2] }), p[1])); });
    box.selected = function () { return Array.prototype.map.call(box.querySelectorAll("input:checked"), function (i) { return i.value; }); };
    return box;
  }

  function pageSnapshots(c) {
    c.appendChild(pageHead("Snapshots & backups", "Snapshots are portable copies of a server - restore them on another machine, OS or runtime. See MIGRATION.md."));
    var parts = partChecks();
    var createBtn = btn("Create snapshot", { kind: "primary" });
    var backupBtn = btn("Back up world now");
    var list = h("div");
    add(c, h("div", { class: "grid cols-2" },
      h("section", { class: "card stack" }, h("h2", { text: "New snapshot" }), parts, h("p", { class: "muted small", text: "Saves the world first if the server is running. Snapshots contain server.conf with passwords - keep them private." }), h("div", { class: "row" }, createBtn)),
      h("section", { class: "card stack" }, h("h2", { text: "Backups" }), h("p", { class: "muted small", text: "Backups are taken automatically on stop and by the scheduled task. Take one now:" }), h("div", { class: "row" }, backupBtn))));
    var sched = h("section", { class: "card", id: "backup-schedule" }), rule = h("section", { class: "card", id: "backup-321" });
    var schedGrid = h("div", { class: "grid cols-2" }, sched, rule);
    schedGrid.style.marginTop = "1rem";
    c.appendChild(schedGrid);
    var loadBackups = function () { return api("GET", "/backups"); };
    var renderRule = section(rule, loadBackups, function (el, d) { backupRule(el, d); });
    section(sched, loadBackups, function (el, d, reload) {
      scheduleEditor(el, d, function () { reload(); clear(renderRule); loadBackups().then(function (b) { backupRule(renderRule, b); }); });
    });
    var listCard = h("section", { class: "card" }, h("div", { class: "card-head" }, h("h2", { text: "Snapshots" }), btn("Refresh", { kind: "ghost sm", icon: "refresh", onclick: function () { load(); } })), list);
    listCard.style.marginTop = "1rem";
    c.appendChild(listCard);
    createBtn.addEventListener("click", function () {
      var inc = parts.selected();
      if (!inc.length) { toast("Pick at least one part", "", "warn"); return; }
      busy(createBtn, runJob("Snapshot", api("POST", "/snapshots", { include: inc })).then(load));
    });
    backupBtn.addEventListener("click", function () { busy(backupBtn, runJob("Backup", api("POST", "/server/backup"))); });
    function load() {
      clear(list).appendChild(loading());
      return api("GET", "/snapshots").then(function (snaps) {
        clear(list);
        if (!snaps.length) { list.appendChild(h("p", { class: "empty", text: "No snapshots yet." })); return; }
        var tbody = h("tbody");
        snaps.forEach(function (s) {
          var restore = btn("Restore", { kind: "sm primary" }), del = btn("Delete", { kind: "sm", aria: "Delete " + s.name });
          restore.addEventListener("click", function () { restoreDialog(s, load); });
          del.addEventListener("click", function () {
            confirmDialog({ title: "Delete this snapshot?", text: s.name + " is deleted for good.", ok: "Delete", danger: true }).then(function (yes) {
              if (yes) busy(del, api("DELETE", "/snapshots/" + encodeURIComponent(s.name)).then(function () { toast("Snapshot deleted"); load(); }, fail));
            });
          });
          var src = s.source ? [s.source.os, s.source.runtime, s.source.host].filter(Boolean).join(" · ") : "–";
          tbody.appendChild(h("tr", null, h("td", { class: "data", "data-label": "Snapshot" }, h("code", { text: s.name }), h("br"), h("span", { class: "muted small", text: (s.server_name || "") })),
            h("td", { "data-label": "Created" }, timeEl(s.created)), h("td", { "data-label": "From", text: src }),
            h("td", { "data-label": "Parts", text: (s.parts || []).join(", ") }), h("td", { "data-label": "Size", text: fmtBytes(s.bytes) }),
            h("td", { class: "actions", "data-label": "Actions" }, restore, " ", del)));
        });
        list.appendChild(h("div", { class: "table-wrap" }, h("table", null, h("thead", null, h("tr", null,
          ["Snapshot", "Created", "From", "Parts", "Size"].map(function (t) { return h("th", { scope: "col", text: t }); }), h("th", null, h("span", { class: "sr-only", text: "Actions" })))), tbody)));
      }, function (e) { clear(list).appendChild(errorCard(e, load)); });
    }
    load();
  }

  var CRON_PRESETS = [
    ["0 5 * * *", "Daily at 05:00"], ["0 */6 * * *", "Every 6 hours"], ["0 * * * *", "Every hour"],
    ["0 5,17 * * *", "Twice a day (05:00, 17:00)"], ["30 4 * * 1", "Weekly, Monday 04:30"], ["off", "Off (no scheduled backups)"]
  ];
  function scheduleEditor(el, d, saved) {
    var expr = h("input", { type: "text", id: "cron-expr", value: d.schedule, spellcheck: "false", autocomplete: "off", "aria-describedby": "cron-help cron-preview",
      placeholder: "minute hour day month weekday" });
    var preset = h("select", { id: "cron-preset", "aria-label": "Schedule preset" }, h("option", { value: "", text: "Custom…" }),
      CRON_PRESETS.map(function (p) { return h("option", { value: p[0], text: p[1], selected: p[0] === d.schedule }); }));
    var preview = h("div", { class: "cron-preview", id: "cron-preview", "aria-live": "polite" });
    var save = btn("Save schedule", { kind: "primary", type: "submit" });
    var timer = null, seq = 0;
    var show = function () {
      var v = expr.value.trim(), mine = ++seq;
      if (!v) { clear(preview).appendChild(h("p", { class: "muted small", text: "Enter a schedule." })); return; }
      api("GET", "/cron/preview?expr=" + encodeURIComponent(v)).then(function (p) {
        if (mine !== seq) return;
        expr.removeAttribute("aria-invalid");
        clear(preview);
        add(preview, [h("p", null, h("strong", { text: p.describe }), h("span", { class: "muted small", text: " (" + p.zone + ")" })),
          p.next.length ? h("ul", { class: "next-runs" }, p.next.map(function (t) { return h("li", null, timeEl(t)); }))
            : h("p", { class: "muted small", text: "Scheduled backups are off - backups still run on stop and when you click Back up." })]);
      }, function (e) {
        if (mine !== seq) return;
        expr.setAttribute("aria-invalid", "true");
        clear(preview).appendChild(h("p", { class: "error-text small", text: e.message }));
      });
    };
    expr.addEventListener("input", function () {
      preset.value = CRON_PRESETS.some(function (p) { return p[0] === expr.value.trim(); }) ? expr.value.trim() : "";
      clearTimeout(timer); timer = setTimeout(show, 250);
    });
    preset.addEventListener("change", function () { if (preset.value) { expr.value = preset.value; show(); } else expr.focus(); });
    var form = h("form", { class: "stack" },
      h("div", { class: "card-head" }, h("h2", { text: "Backup schedule" })),
      h("div", { class: "field" }, h("label", { for: "cron-preset", text: "Preset" }), preset),
      h("div", { class: "field" }, h("label", { for: "cron-expr", text: "Schedule (cron)" }), h("div", { class: "input-group" }, expr, save),
        h("span", { class: "hint", id: "cron-help", text: "minute hour day-of-month month day-of-week, like cron: */15 = every 15, 1-5 = Mon-Fri, MON,THU, @daily, @hourly, or off. Times are in the server's time zone." })),
      preview);
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      busy(save, api("PUT", "/backups/schedule", { schedule: expr.value.trim() }).then(function () { toast("Backup schedule saved", expr.value.trim()); saved(); }, fail));
    });
    el.appendChild(form);
    show();
  }
  function backupRule(el, d) {
    var r = d.rule321 || {};
    var item = function (ok, title, text) {
      return h("li", { class: ok ? "ok" : "bad" }, h("span", { class: "pill " + (ok ? "ok" : "warn"), text: ok ? "Yes" : "No" }),
        h("div", null, h("strong", { text: title }), h("p", { class: "muted small" }, text)));
    };
    var last = d.last && d.last.file ? [h("code", { text: d.last.file })] : ["none yet"];
    add(el, [
      h("div", { class: "card-head" }, h("h2", { text: "3-2-1 check" }), h("span", { class: "pill " + (r.ok ? "ok" : "warn"), text: r.ok ? "3-2-1 met" : "Not 3-2-1 yet" })),
      h("p", { class: "muted small", text: "3 copies of your world, on 2 different disks or media, 1 of them off-site." }),
      h("ul", { class: "checks" },
        item(r.copies >= 3, (r.copies || 0) + " of 3 copies", "Local backups (" + (d.local ? d.local.count : 0) + " in " + (d.local ? d.local.dir : "?") + ")" +
          (d.copy && d.copy.dir ? ", a second copy in " + d.copy.dir : "") + (d.offsite && d.offsite.configured ? ", and off-site" : "") + "."),
        item(r.media >= 2, (r.media || 0) + " of 2 media", d.copy && d.copy.dir ? (d.copy.other_disk ? "BACKUP_COPY_DIR is on another disk." : "BACKUP_COPY_DIR is on the same disk as the backups - use another drive or a network share.")
          : "Set BACKUP_COPY_DIR in server.conf to a second drive or network share."),
        item(!!r.offsite, "Off-site", d.offsite && d.offsite.configured ? "BACKUP_OFFSITE_COMMAND runs after every backup" + (d.offsite.last ? " (last " + d.offsite.last.replace("T", " ") + ")." : ".")
          : "Set BACKUP_OFFSITE_COMMAND in server.conf (e.g. rclone copy {file} remote:isle), or enable the offsite-backup plugin.")),
      h("p", { class: "muted small" }, "Last backup: ", last),
      h("p", { class: "muted small", text: "The copy folder and off-site command are machine settings: edit them in config/server.conf on the server (they are not editable here)." })]);
  }

  function restoreDialog(s, after) {
    var parts = partChecks(s.parts);
    var overwrite = h("input", { type: "checkbox" }), stop = h("input", { type: "checkbox", checked: true });
    var extra = h("div", { class: "stack" }, h("div", { class: "field" }, h("span", { class: "small", text: "Restore these parts" }), parts),
      h("label", { class: "check" }, overwrite, "Replace the current world (it is kept as Saved.pre-snapshot-…)"),
      h("label", { class: "check" }, stop, "Stop the server first if it is running"));
    confirmDialog({ title: "Restore " + s.name + "?", text: "Settings are merged; machine-specific settings are kept.", ok: "Restore", extra: extra }).then(function (yes) {
      if (!yes) return;
      runJob("Restore", api("POST", "/snapshots/" + encodeURIComponent(s.name) + "/restore", { include: parts.selected(), overwrite: overwrite.checked, stop: stop.checked })).then(after);
    });
  }

  function pageLogs(c) {
    var lines = h("select", { "aria-label": "Lines" }, [100, 200, 500, 1000, 2000].map(function (n) { return h("option", { value: n, text: n + " lines", selected: n === 200 }); }));
    var source = h("select", { "aria-label": "Log", id: "log-source" }, h("option", { value: "", text: "Game log (TheIsle.log)" }));
    var auto = h("input", { type: "checkbox", role: "switch" });
    var refresh = btn("Refresh", { icon: "refresh" });
    c.appendChild(pageHead("Logs", "The game's log, or a rotated launcher / server console / web UI log (KIND_yyyymmdd_hhmmss.log).",
      [source, lines, h("label", { class: "switch" }, auto, h("span", { class: "track" }), h("span", { text: "Auto-refresh" })), refresh]));
    api("GET", "/log-files").then(function (files) {
      files.forEach(function (f) {
        source.appendChild(h("option", { value: f.name, text: f.name + " · " + fmtBytes(f.bytes) + " · " + fmtTime(f.modified) }));
      });
    }, function () { /* older API: game log only */ });
    var pre = h("pre", { class: "log", tabindex: "0", "aria-label": "Server log", text: "Loading…" });
    c.appendChild(h("section", { class: "card" }, pre));
    var timer = null;
    function load() {
      var url = source.value ? "/log-files/" + encodeURIComponent(source.value) + "?lines=" + lines.value : "/logs?lines=" + lines.value;
      return api("GET", url).then(function (d) {
        var atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
        pre.textContent = d.lines.length ? d.lines.join("\n") : "(the log is empty)";
        if (atBottom || !timer) pre.scrollTop = pre.scrollHeight;
      }, function (e) { pre.textContent = e.message; });
    }
    refresh.addEventListener("click", function () { busy(refresh, load()); });
    lines.addEventListener("change", load);
    source.addEventListener("change", load);
    auto.addEventListener("change", function () {
      clearInterval(timer); timer = null;
      if (auto.checked) timer = setInterval(function () { if (!document.hidden) load(); }, 5000);
    });
    load();
    return function () { clearInterval(timer); };
  }

  var RCON_HINTS = { announce: "message", directmessage: "SteamID64 message", kick: "SteamID64 reason", ban: "SteamID64 reason",
    updateplayables: "Class1,Class2", whitelist: "SteamID64", removewhitelist: "SteamID64", toggleai: "", wipecorpses: "", save: "" };
  function pageConsole(c) {
    c.appendChild(pageHead("RCON console", "Send commands to the running server."));
    var sel = h("select", { id: "rcon-cmd" });
    var args = h("input", { type: "text", id: "rcon-args", spellcheck: "false", autocomplete: "off" });
    var send = btn("Send", { kind: "primary", type: "submit" });
    var log = h("pre", { class: "log", tabindex: "0", "aria-live": "polite", "aria-label": "RCON replies" });
    var form = h("form", { class: "grid cols-2" }, h("div", { class: "field" }, h("label", { for: "rcon-cmd", text: "Command" }), sel),
      h("div", { class: "field" }, h("label", { for: "rcon-args", text: "Arguments" }), h("div", { class: "input-group" }, args, send)));
    add(c, [h("section", { class: "card" }, form), h("section", { class: "card" }, h("div", { class: "card-head" }, h("h2", { text: "Replies" }),
      btn("Clear", { kind: "ghost sm", onclick: function () { log.textContent = ""; } })), log)]);
    c.lastChild.style.marginTop = "1rem";
    var fill = function (cmds) {
      clear(sel);
      cmds.forEach(function (cmd) { sel.appendChild(h("option", { value: cmd, text: cmd, selected: cmd === "announce" })); });
      sel.dispatchEvent(new Event("change"));
    };
    sel.addEventListener("change", function () { args.placeholder = RCON_HINTS[sel.value] !== undefined ? RCON_HINTS[sel.value] || "(no arguments)" : "arguments"; });
    if (state.rconCommands.length) fill(state.rconCommands);
    else fetch("/openapi.json").then(function (r) { return r.json(); }).then(function (spec) {
      state.rconCommands = spec.paths["/api/v1/rcon"].post.requestBody.content["application/json"].schema.properties.command["enum"];
      fill(state.rconCommands);
    }).catch(function () { fill(["announce", "save"]); });
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var a = args.value.trim();
      var line = "> " + sel.value + (a ? " " + a : "");
      log.textContent += (log.textContent ? "\n" : "") + line;
      busy(send, api("POST", "/rcon", { command: sel.value, args: a ? [a] : [] }).then(function (r) {
        log.textContent += "\n" + (r.reply || "(ok)");
      }, function (e) { log.textContent += "\n! " + e.message; }).finally(function () { log.scrollTop = log.scrollHeight; }));
    });
  }

  var TOGGLES = [
    ["pause", "Pause the server", "Freezes the game for everyone."], ["migrations", "Migrations", "AI and players' migration zones."],
    ["humans", "Humans", "Lets players spawn as humans."], ["chat", "Global chat", "Server-wide chat."],
    ["ai-learning", "AI learning", "AI adapts to players."], ["netupdate", "Network update distance", "Experimental network optimisation."]
  ];
  function pageAdmin(c) {
    c.appendChild(pageHead("Admin", "Live admin commands over RCON. The server must be running with RCON enabled."));
    var out = h("pre", { class: "log", tabindex: "0", "aria-live": "polite", "aria-label": "Admin replies", id: "admin-output" });
    var say = function (label, r) { out.textContent += (out.textContent ? "\n" : "") + "> " + label + "\n" + ((r && r.output) || "(ok)").trim(); out.scrollTop = out.scrollHeight; };
    var run = function (b, action, body, label) {
      return busy(b, api("POST", "/admin/" + action, body || {}).then(function (r) { say(label || action, r); return r; },
        function (e) { say(label || action, { output: "! " + e.message }); fail(e); }));
    };
    var sid = function () { return h("input", { type: "text", inputmode: "numeric", spellcheck: "false", autocomplete: "off", placeholder: "SteamID64", "aria-label": "SteamID64" }); };
    var needId = function (input) {
      if (STEAMID.test(input.value.trim())) { input.removeAttribute("aria-invalid"); return input.value.trim(); }
      input.setAttribute("aria-invalid", "true"); toast("Not a SteamID64", "17 digits starting with 7656119", "error"); input.focus(); return null;
    };

    // players
    var players = h("div");
    var refresh = btn("Refresh", { kind: "sm", icon: "refresh" });
    var listPlayers = function () {
      return run(refresh, "players", {}, "players").then(function (r) {
        clear(players);
        if (!r) return;
        var ul = h("ul", { class: "list" });
        (r.output || "").split("\n").forEach(function (line) {
          var m = line.match(/7656119\d{10}/);
          if (!m) return;
          var id = m[0], name = line.replace(id, "").replace(/^[\s,:;|-]+|[\s,:;|-]+$/g, "") || "(unnamed)";
          var acts = h("span", { class: "row" });
          [["Data", "player", false], ["Message", "dm", "text"], ["Kick", "kick", "reason"], ["Ban", "ban", "reason"]].forEach(function (a) {
            var b = btn(a[0], { kind: "sm" + (a[1] === "ban" ? " danger" : ""), aria: a[0] + " " + name });
            b.addEventListener("click", function () { playerAction(b, a, id, name); });
            acts.appendChild(b);
          });
          add(ul, h("li", null, h("span", { class: "who" }, h("strong", { text: name, "data-peek": name }), h("code", { class: "small", text: id })), acts));
        });
        players.appendChild(ul.childNodes.length ? ul : h("p", { class: "empty", text: "No players online." }));
      });
    };
    var playerAction = function (b, a, id, name) {
      if (!a[2]) { run(b, a[1], { steam_id: id }, a[1] + " " + name); return; }
      var text = h("input", { type: "text", maxlength: "500", "aria-label": a[2] === "text" ? "Message" : "Reason", placeholder: a[2] === "text" ? "Message" : "Reason (optional)" });
      confirmDialog({ title: a[0] + " " + name + "?", text: id, ok: a[0], danger: a[1] !== "dm", extra: h("div", { class: "field" }, text) }).then(function (yes) {
        if (!yes) return;
        if (a[2] === "text" && !text.value.trim()) { toast("Type a message", "", "warn"); return; }
        run(b, a[1], { steam_id: id, text: text.value.trim() }, a[1] + " " + name).then(function () { if (a[1] !== "dm") listPlayers(); });
      });
    };
    var playersCard = h("section", { class: "card" }, h("div", { class: "card-head" }, h("h2", { text: "Players online" }), refresh), players);
    refresh.addEventListener("click", listPlayers);
    players.appendChild(h("p", { class: "muted small", text: "Click Refresh to ask the server who is online." }));

    // messages
    var annText = h("input", { type: "text", maxlength: "500", id: "announce-text", placeholder: "Message to everyone" });
    var annBtn = btn("Announce", { kind: "primary", type: "submit" });
    var annForm = h("form", { class: "field" }, h("label", { for: "announce-text", text: "Announcement" }), h("div", { class: "input-group" }, annText, annBtn));
    annForm.addEventListener("submit", function (ev) { ev.preventDefault(); if (annText.value.trim()) run(annBtn, "announce", { text: annText.value.trim() }, "announce").then(function () { annText.value = ""; }); });
    var dmId = sid(), dmText = h("input", { type: "text", maxlength: "500", placeholder: "Private message", "aria-label": "Private message" }), dmBtn = btn("Send", { type: "submit" });
    var dmForm = h("form", { class: "field" }, h("span", { class: "label-text", text: "Direct message / kick / ban by SteamID64" }),
      h("div", { class: "input-group" }, dmId, dmText, dmBtn));
    dmForm.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var id = needId(dmId);
      if (id && dmText.value.trim()) run(dmBtn, "dm", { steam_id: id, text: dmText.value.trim() }, "dm " + id);
    });
    var byId = h("div", { class: "row" });
    [["Kick", "kick"], ["Ban", "ban"], ["Player data", "player"]].forEach(function (a) {
      var b = btn(a[0], { kind: "sm" + (a[1] === "ban" ? " danger" : "") });
      b.addEventListener("click", function () {
        var id = needId(dmId);
        if (id) playerAction(b, [a[0], a[1], a[1] === "player" ? false : "reason"], id, id);
      });
      byId.appendChild(b);
    });
    var msgCard = h("section", { class: "card stack" }, h("h2", { text: "Messages & moderation" }), annForm, dmForm, byId);

    // live switches
    var toggles = h("ul", { class: "list toggles" });
    TOGGLES.forEach(function (t) {
      var on = btn("On", { kind: "sm", aria: t[1] + " on" }), off = btn("Off", { kind: "sm", aria: t[1] + " off" });
      on.addEventListener("click", function () { run(on, t[0], { value: "on" }, t[0] + " on"); });
      off.addEventListener("click", function () { run(off, t[0], { value: "off" }, t[0] + " off"); });
      add(toggles, h("li", null, h("div", null, h("strong", { text: t[1] }), h("p", { class: "muted small", text: t[2] })), h("span", { class: "row" }, on, off)));
    });
    var growth = h("input", { type: "number", min: "0", step: "0.1", value: "1", id: "growth-value", class: "num" });
    var gSet = btn("Set", { kind: "sm", type: "submit" }), gOn = btn("On", { kind: "sm", aria: "Growth multiplier on" }), gOff = btn("Off", { kind: "sm", aria: "Growth multiplier off" });
    gOn.addEventListener("click", function () { run(gOn, "growth", { value: "on" }, "growth on"); });
    gOff.addEventListener("click", function () { run(gOff, "growth", { value: "off" }, "growth off"); });
    var gForm = h("form", { class: "row", novalidate: true }, h("label", { for: "growth-value", class: "small", text: "×" }), growth, gSet);
    gForm.addEventListener("submit", function (ev) {
      ev.preventDefault();
      if (!/^\d+(\.\d+)?$/.test(growth.value.trim())) { growth.setAttribute("aria-invalid", "true"); toast("Multiplier must be a number", "", "error"); return; }
      growth.removeAttribute("aria-invalid");
      run(gSet, "growth", { value: growth.value.trim() }, "growth " + growth.value.trim());
    });
    add(toggles, h("li", null, h("div", null, h("strong", { text: "Growth multiplier" }), h("p", { class: "muted small", text: "Speeds up how fast dinosaurs grow." })),
      h("span", { class: "row" }, gOn, gOff, gForm)));
    var liveCard = h("section", { class: "card" }, h("h2", { text: "Live switches" }),
      h("p", { class: "muted small", text: "The server does not report the current state of these; they reset to server.conf on restart." }), toggles);

    // server
    var srv = h("div", { class: "row" });
    [["Save world", "save"], ["Queue status", "queue"], ["Playable classes", "playables"], ["Server details", "details"], ["Wipe corpses", "wipecorpses"]].forEach(function (a) {
      var b = btn(a[0], { kind: "sm" });
      b.addEventListener("click", function () {
        if (a[1] !== "wipecorpses") { run(b, a[1], {}, a[1]); return; }
        confirmDialog({ title: "Wipe all corpses?", text: "Removes every carcass on the map - carnivores lose that food.", ok: "Wipe corpses", danger: true })
          .then(function (yes) { if (yes) run(b, "wipecorpses", {}, "wipecorpses"); });
      });
      srv.appendChild(b);
    });
    var custom = h("input", { type: "text", maxlength: "500", id: "custom-cmd", spellcheck: "false", autocomplete: "off", placeholder: "Experimental: raw command" });
    var cBtn = btn("Send", { type: "submit" });
    var cForm = h("form", { class: "field" }, h("label", { for: "custom-cmd", text: "Custom command" }), h("div", { class: "input-group" }, custom, cBtn),
      h("span", { class: "hint", text: "Sent as-is with the experimental custom RCON opcode. Most builds ignore it." }));
    cForm.addEventListener("submit", function (ev) {
      ev.preventDefault();
      if (!custom.value.trim()) return;
      confirmDialog({ title: "Send a custom command?", text: custom.value.trim(), ok: "Send" }).then(function (yes) { if (yes) run(cBtn, "custom", { text: custom.value.trim() }, "custom " + custom.value.trim()); });
    });
    var srvCard = h("section", { class: "card stack" }, h("h2", { text: "Server" }), srv, cForm);

    var note = h("div", { class: "callout", role: "note" }, h("strong", { text: "Not available over RCON: " }),
      "Evrima's RCON has no commands to change a player's size/growth, skin, mutations, give god mode, teleport or heal. Admins listed on the ",
      h("a", { href: "#/players", text: "Players" }), " page do those in game with the game's own admin panel. Mutations available on the server are set on ",
      h("a", { href: "#/world", text: "Map & AI" }), ".");
    var replies = h("section", { class: "card" }, h("div", { class: "card-head" }, h("h2", { text: "Replies" }),
      btn("Clear", { kind: "ghost sm", onclick: function () { out.textContent = ""; } })), out);
    add(c, [note, h("div", { class: "grid admin-grid gap-top" }, playersCard, msgCard, srvCard, liveCard), replies]);
    replies.style.marginTop = "1rem";
    if (state.status && state.status.running) listPlayers();
  }

  // ----------------------------------------------------------- date & time
  function dateTimeDialog() {
    var T = window.IsleTime;
    var zone = T.getZone(), fmt = T.getFormat();
    var preview = h("output", { class: "preview", "aria-live": "polite" });
    var zones = h("fieldset", { class: "stack" }, h("legend", { text: "Time zone" }));
    [["server", "Server time", T.zoneInfo("server").label], ["browser", "This browser", T.zoneInfo("browser").label.replace(" (this browser)", "")],
      ["utc", "UTC", "UTC"]].forEach(function (z) {
      var r = h("input", { type: "radio", name: "tz", value: z[0], checked: zone === z[0] });
      r.addEventListener("change", function () { zone = z[0]; paint(); });
      zones.appendChild(h("label", { class: "check" }, r, z[1], h("span", { class: "muted small", text: " · " + z[2] })));
    });
    var isPreset = T.PRESETS.some(function (p) { return p.id === fmt; });
    var select = h("select", { id: "date-format", "aria-label": "Date format" },
      T.PRESETS.map(function (p) { return h("option", { value: p.id, text: p.label, selected: p.id === fmt }); }),
      h("option", { value: "custom", text: "Custom…", selected: !isPreset }));
    var custom = h("input", { type: "text", id: "date-format-custom", value: fmt, spellcheck: "false", autocomplete: "off", "aria-describedby": "date-tokens" });
    var customField = h("div", { class: "field" }, h("label", { for: "date-format-custom", text: "Custom pattern" }), custom,
      h("span", { class: "hint", id: "date-tokens", text: "yyyy yy · MMMM MMM MM M · dd d · EEEE EEE · HH H hh h · mm ss · a (AM/PM) · ZZ (zone) · 'text'" }));
    customField.hidden = isPreset;
    function paint() {
      fmt = select.value === "custom" ? (custom.value.trim() || T.DEFAULT_FMT) : select.value;
      customField.hidden = select.value !== "custom";
      preview.textContent = T.format(new Date(), fmt, zone);
    }
    select.addEventListener("change", function () { if (select.value === "custom") custom.value = fmt; paint(); });
    custom.addEventListener("input", paint);
    var save = btn("Save", { kind: "primary" });
    var dlg = modal("Date & time", h("div", { class: "stack" }, zones,
      h("div", { class: "field" }, h("label", { for: "date-format", text: "Date format" }), select), customField,
      h("div", { class: "field" }, h("span", { class: "small", text: "Preview" }), preview),
      h("p", { class: "muted small", text: "Saved in this browser. Log files and backup names use the server's TIMEZONE setting." }),
      h("div", { class: "actions" }, btn("Cancel", { onclick: function () { dlg.close(); } }), save)));
    save.addEventListener("click", function () {
      T.setZone(zone); T.setFormat(fmt); dlg.close();
      toast("Date & time saved", T.format(new Date(), fmt, zone));
      navigate();
    });
    paint();
  }

  // ---------------------------------------------------------------- router
  var ROUTES = {
    "/": ["Dashboard", pageDashboard], "/settings": ["Settings", pageSettings], "/players": ["Players", pagePlayers],
    "/roster": ["Roster", pageRoster], "/profiles": ["Profiles & presets", pageProfiles], "/plugins": ["Plugins", pagePlugins],
    "/snapshots": ["Snapshots & backups", pageSnapshots], "/logs": ["Logs", pageLogs], "/console": ["RCON console", pageConsole],
    "/world": ["Map & AI", pageWorld], "/admin": ["Admin", pageAdmin]
  };
  function navigate() {
    if (!state.token) return;
    var path = ((location.hash || "#/").slice(1) || "/").split("?")[0] || "/";
    var r = ROUTES[path] || ROUTES["/"];
    if (typeof state.cleanup === "function") { try { state.cleanup(); } catch (e) { /* ignore */ } }
    var content = clear($("#content"));
    state.cleanup = r[1](content);
    document.title = r[0] + " · The Isle Server";
    document.querySelectorAll("#nav a").forEach(function (a) {
      if (a.getAttribute("href") === "#" + path || (path === "/" && a.getAttribute("href") === "#/")) a.setAttribute("aria-current", "page");
      else a.removeAttribute("aria-current");
    });
    $("#app").classList.remove("nav-open");
    $("#menu").setAttribute("aria-expanded", "false");
    content.focus({ preventScroll: true });
    window.scrollTo(0, 0);
  }

  // ------------------------------------------------------------ auth/start
  var statusTimer = null;
  function showApp() {
    $("#login").hidden = true; $("#app").hidden = false;
    fetch("/api/v1/health").then(function (r) { return r.json(); }).then(function (hlth) { $("#version").textContent = "v" + hlth.version + " · API " + hlth.api_version; }).catch(function () {});
    refreshStatus();
    clearInterval(statusTimer);
    statusTimer = setInterval(function () { if (!document.hidden) refreshStatus(); }, 10000);
    navigate();
  }
  function signOut(message) {
    state.token = null;
    try { sessionStorage.removeItem(TOKEN_KEY); } catch (e) { /* ignore */ }
    clearInterval(statusTimer);
    $("#app").hidden = true; $("#login").hidden = false;
    var err = $("#login-error");
    err.hidden = !message; err.textContent = message || "";
    $("#token").focus();
  }
  function init() {
    window.IsleTheme.bind($("#theme-switch"));
    var form = $("#login-form"), tokenInput = $("#token"), show = $("#token-show");
    show.addEventListener("click", function () {
      var on = tokenInput.type === "password";
      tokenInput.type = on ? "text" : "password"; show.textContent = on ? "Hide" : "Show"; show.setAttribute("aria-pressed", String(on));
    });
    form.addEventListener("submit", function (ev) {
      ev.preventDefault();
      var submit = form.querySelector('button[type="submit"]');
      var candidate = tokenInput.value.trim();
      submit.setAttribute("aria-busy", "true");
      fetch("/api/v1/status", { headers: { Authorization: "Bearer " + candidate }, cache: "no-store" }).then(function (res) {
        submit.removeAttribute("aria-busy");
        if (res.status === 401) throw new Error("That token is not right.");
        if (res.status === 429) throw new Error("Too many wrong tokens - wait a minute and try again.");
        state.token = candidate;
        try { sessionStorage.setItem(TOKEN_KEY, candidate); } catch (e) { /* not remembered */ }
        tokenInput.value = "";
        showApp();
      }).catch(function (e) {
        submit.removeAttribute("aria-busy");
        var err = $("#login-error"); err.hidden = false; err.textContent = e.message.indexOf("token") >= 0 || e.message.indexOf("wait") >= 0 ? e.message : "Cannot reach the server.";
      });
    });
    $("#logout").addEventListener("click", function () { signOut(""); });
    $("#datetime").addEventListener("click", dateTimeDialog);
    $("#menu").addEventListener("click", function () {
      var open = $("#app").classList.toggle("nav-open");
      $("#menu").setAttribute("aria-expanded", String(open));
    });
    document.querySelector(".main").addEventListener("click", function (e) {
      if ($("#app").classList.contains("nav-open") && !e.target.closest("#menu")) { $("#app").classList.remove("nav-open"); $("#menu").setAttribute("aria-expanded", "false"); }
    });
    $("#modal-close").addEventListener("click", function () { $("#modal").close(); });
    window.addEventListener("hashchange", navigate);
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") $("#app").classList.remove("nav-open"); });
    try { state.token = state.token || sessionStorage.getItem(TOKEN_KEY); } catch (e) { /* ignore */ }
    if (state.token) showApp(); else signOut("");
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
