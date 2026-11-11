/* Guided tour of the web UI (PRD UI-09). window.IsleTour.start() walks through the main areas: it highlights
   each one, explains it, and moves on with Next / Back / the arrow keys; Esc or "Skip tour" ends it.
   It never starts on its own (a modal surprise breaks flows); the sidebar and the welcome card offer it.
   Vanilla ES5, text via textContent only, CSP-safe (styles through the CSSOM). */
(function () {
  "use strict";

  var STEPS = [
    { title: "Welcome to your server's control panel", text: "This short tour shows where everything is. Use Next or the arrow keys; Esc ends it at any time." },
    { target: "#status-pill", title: "Server status", text: "Running, stopped or working on a job. It refreshes on its own." },
    { target: ".hero", route: "/", title: "Quick actions", text: "Start, stop, restart, save the world and back up. Long actions run as jobs with live output." },
    { target: "#nav a[href='#/setup']", title: "Get started", text: "The setup wizard: checks this machine, recommends settings that fit it, and walks you through name, map, admins, play style and backups." },
    { target: "#nav a[href='#/settings']", title: "Settings", text: "Every server.conf setting, grouped and searchable. Changes are checked before they are saved and rolled back if invalid." },
    { target: "#nav a[href='#/players']", title: "Players", text: "Admins and the whitelist, with each player's Steam name. Click a name to open the Steam profile." },
    { target: "#nav a[href='#/roster']", title: "Roster", text: "Which dinosaurs players can pick - filter by type (carnivore, flying, ...), plus the humans switch." },
    { target: "#nav a[href='#/world']", title: "Map & AI", text: "Switch maps, tune AI creatures and choose which mutations exist." },
    { target: "#nav a[href='#/snapshots']", title: "Snapshots & backups", text: "When backups run, your 3-2-1 strategy (second disk, off-site) and portable snapshots to move a server." },
    { target: "#nav a[href='#/admin']", title: "Admin", text: "Live commands for a running server: players online, kick, ban, messages, live switches and more." },
    { target: "#nav a[href='#/logs']", title: "Logs", text: "The game's log and the rotated launcher, server and UI logs." },
    { target: "#theme-switch", title: "Look and time", text: "Light, dark or your system's theme. Date & time next to it sets the time zone and date format." },
    { target: "#tour-start", title: "That's it", text: "Start this tour again from here whenever you like. Have fun with your server!" }
  ];
  var DONE_KEY = "isle-tour-done";
  var state = null;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text) e.textContent = text;
    return e;
  }
  function reduced() { return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches; }
  function visible(node) {
    if (!node) return false;
    var r = node.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(node).visibility !== "hidden";
  }
  function menuMode() { var m = document.getElementById("menu"); return visible(m); }   // phone/tablet layout
  function setMenu(open) {
    var app = document.getElementById("app"), menu = document.getElementById("menu");
    if (!app || !menu || !menuMode()) return;
    if (app.classList.contains("nav-open") !== open) menu.click();
  }

  function build() {
    var root = el("div", "tour");
    root.id = "tour";
    var spot = el("div", "tour-spot");
    var pop = el("div", "tour-pop");
    pop.setAttribute("role", "dialog");
    pop.setAttribute("aria-modal", "true");
    pop.setAttribute("aria-labelledby", "tour-title");
    pop.setAttribute("aria-describedby", "tour-text");
    var count = el("span", "tour-count muted small");
    var title = el("h2", "tour-title"); title.id = "tour-title"; title.tabIndex = -1;
    var text = el("p", "tour-text"); text.id = "tour-text";
    var row = el("div", "tour-actions");
    var skip = el("button", "btn ghost sm", "Skip tour"); skip.type = "button";
    var back = el("button", "btn sm", "Back"); back.type = "button";
    var next = el("button", "btn primary sm", "Next"); next.type = "button";
    row.appendChild(skip); row.appendChild(el("span", "tour-gap")); row.appendChild(back); row.appendChild(next);
    pop.appendChild(count); pop.appendChild(title); pop.appendChild(text); pop.appendChild(row);
    root.appendChild(spot); root.appendChild(pop);
    skip.addEventListener("click", function () { end(true); });
    back.addEventListener("click", function () { show(state.i - 1); });
    next.addEventListener("click", function () { if (state.i >= STEPS.length - 1) end(true); else show(state.i + 1); });
    root.addEventListener("click", function (ev) { if (ev.target === root) end(false); });   // click outside: close without marking done
    return { root: root, spot: spot, pop: pop, count: count, title: title, text: text, back: back, next: next, skip: skip };
  }

  function place() {
    if (!state) return;
    var ui = state.ui, step = STEPS[state.i], target = step.target ? document.querySelector(step.target) : null;
    var vw = window.innerWidth, vh = window.innerHeight, pad = 8, gap = 12;
    if (target && visible(target)) {
      var r = target.getBoundingClientRect();
      ui.spot.hidden = false;
      ui.spot.style.left = Math.max(2, r.left - 6) + "px";
      ui.spot.style.top = Math.max(2, r.top - 6) + "px";
      ui.spot.style.width = Math.min(vw - 4, r.width + 12) + "px";
      ui.spot.style.height = Math.min(vh - 4, r.height + 12) + "px";
      ui.root.classList.remove("centered");
      var pw = ui.pop.offsetWidth, ph = ui.pop.offsetHeight;
      var left, top;
      if (r.right + gap + pw <= vw - pad && r.width < vw * 0.5) {              // to the right (sidebar items)
        left = r.right + gap; top = r.top + r.height / 2 - ph / 2;
      } else if (r.bottom + gap + ph <= vh - pad) {                           // below
        left = r.left + r.width / 2 - pw / 2; top = r.bottom + gap;
      } else if (r.top - gap - ph >= pad) {                                   // above
        left = r.left + r.width / 2 - pw / 2; top = r.top - gap - ph;
      } else {                                                                // no room: bottom of the screen
        left = (vw - pw) / 2; top = vh - ph - pad;
      }
      ui.pop.style.left = Math.round(Math.max(pad, Math.min(left, vw - pw - pad))) + "px";
      ui.pop.style.top = Math.round(Math.max(pad, Math.min(top, vh - ph - pad))) + "px";
    } else {
      ui.spot.hidden = true;
      ui.root.classList.add("centered");
      ui.pop.style.left = Math.round(Math.max(pad, (vw - ui.pop.offsetWidth) / 2)) + "px";
      ui.pop.style.top = Math.round(Math.max(pad, (vh - ui.pop.offsetHeight) / 2)) + "px";
    }
  }

  function show(i) {
    if (!state) return;
    state.i = Math.max(0, Math.min(STEPS.length - 1, i));
    var step = STEPS[state.i], ui = state.ui;
    var go = function () {
      var inNav = step.target && step.target.indexOf("#nav") === 0 || step.target === "#theme-switch" || step.target === "#tour-start";
      setMenu(!!inNav);
      ui.count.textContent = "Step " + (state.i + 1) + " of " + STEPS.length;
      ui.title.textContent = step.title;
      ui.text.textContent = step.text;
      ui.back.disabled = state.i === 0;
      ui.next.textContent = state.i === STEPS.length - 1 ? "Done" : "Next";
      var target = step.target ? document.querySelector(step.target) : null;
      if (target && target.scrollIntoView) target.scrollIntoView({ block: "nearest", inline: "nearest", behavior: reduced() ? "auto" : "smooth" });
      setTimeout(function () { place(); ui.title.focus({ preventScroll: true }); }, reduced() ? 0 : 220);
    };
    if (step.route && (location.hash || "#/").slice(1).split("?")[0] !== step.route) {
      location.hash = "#" + step.route;
      setTimeout(go, 250);   // let the page render
    } else {
      go();
    }
  }

  function onKey(ev) {
    if (!state) return;
    if (ev.key === "Escape") { ev.preventDefault(); end(false); }
    else if (ev.key === "ArrowRight") { ev.preventDefault(); if (state.i < STEPS.length - 1) show(state.i + 1); }
    else if (ev.key === "ArrowLeft") { ev.preventDefault(); show(state.i - 1); }
    else if (ev.key === "Tab") {   // keep focus inside the tour card
      var f = [state.ui.skip, state.ui.back, state.ui.next].filter(function (b) { return !b.disabled; });
      var at = f.indexOf(document.activeElement);
      ev.preventDefault();
      f[(at + (ev.shiftKey ? -1 : 1) + f.length) % f.length].focus();
    }
  }
  function onMove() { if (state) place(); }

  function start() {
    if (state) return;
    var ui = build();
    state = { ui: ui, i: 0, returnFocus: document.activeElement };
    document.body.appendChild(ui.root);
    document.addEventListener("keydown", onKey, true);
    window.addEventListener("resize", onMove);
    window.addEventListener("scroll", onMove, true);
    show(0);
  }
  function end(markDone) {
    if (!state) return;
    var s = state;
    state = null;
    document.removeEventListener("keydown", onKey, true);
    window.removeEventListener("resize", onMove);
    window.removeEventListener("scroll", onMove, true);
    if (s.ui.root.parentNode) s.ui.root.parentNode.removeChild(s.ui.root);
    setMenu(false);
    if (markDone) { try { localStorage.setItem(DONE_KEY, "1"); } catch (e) { /* storage blocked */ } }
    var back = document.getElementById("tour-start") || s.returnFocus;
    if (back && back.focus && visible(back)) back.focus();
  }
  function seen() { try { return localStorage.getItem(DONE_KEY) === "1"; } catch (e) { return false; } }

  window.IsleTour = { start: start, end: end, seen: seen, steps: STEPS, active: function () { return !!state; } };
  document.addEventListener("DOMContentLoaded", function () {
    var b = document.getElementById("tour-start");
    if (b) b.addEventListener("click", function () { start(); });
  });
})();
