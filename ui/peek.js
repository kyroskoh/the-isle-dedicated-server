/* Instant "peek" for truncated text (PRD UI-02): hovering, focusing or tapping any element whose text is
   cut off (ellipsis / clipped) - or that has data-peek - shows the full text right away, without the
   browser's tooltip delay. Works with mouse, keyboard and touch; kept inside the viewport. */
(function () {
  "use strict";
  var tip = null, target = null, touchShown = false;

  function truncated(el) {
    if (!el || el.nodeType !== 1 || el.closest("input, textarea, select, pre, .peek")) return false;
    if (el.hasAttribute("data-peek")) return true;
    var cs = getComputedStyle(el);
    // only clipped text (ellipsis / overflow hidden); scrollable areas and dialogs are not "truncated"
    var clipX = cs.overflowX === "hidden" || cs.overflowX === "clip", clipY = cs.overflowY === "hidden" || cs.overflowY === "clip";
    if (!clipX && !clipY) return false;
    if (el.matches("dialog, .card, .sidebar, .table-wrap, .content, main, body")) return false;
    return (clipX && el.scrollWidth > el.clientWidth + 1) || (clipY && el.scrollHeight > el.clientHeight + 1);
  }
  /* the nearest element (self or ancestor, up to 4 levels) that is truncated; or a chip/label whose child is */
  function findTarget(node) {
    for (var el = node, i = 0; el && el !== document.body && i < 5; el = el.parentElement, i++) {
      if (truncated(el)) return el;
      if (el.matches && el.matches(".chip, label, .pill, .badge, td, .title")) {
        var inner = el.querySelectorAll("span, strong, code");
        for (var j = 0; j < inner.length; j++) if (truncated(inner[j])) return inner[j];
      }
    }
    return null;
  }
  function text(el) {
    return (el.getAttribute("data-peek") || el.textContent || "").replace(/\s+/g, " ").trim();
  }
  function ensureTip() {
    if (tip) return tip;
    tip = document.createElement("div");
    tip.className = "peek";
    tip.id = "peek";
    tip.setAttribute("role", "tooltip");
    tip.hidden = true;
    document.body.appendChild(tip);
    return tip;
  }
  function place(el) {
    var r = el.getBoundingClientRect(), t = ensureTip(), m = 8;
    t.style.left = "0px"; t.style.top = "0px"; t.hidden = false;
    var w = t.offsetWidth, hgt = t.offsetHeight, vw = document.documentElement.clientWidth, vh = document.documentElement.clientHeight;
    var left = Math.min(Math.max(m, r.left), Math.max(m, vw - w - m));
    var top = r.bottom + 6;
    if (top + hgt > vh - m && r.top - hgt - 6 >= m) top = r.top - hgt - 6;   // flip above when there is no room below
    t.style.left = Math.round(left) + "px";
    t.style.top = Math.round(Math.max(m, Math.min(top, vh - hgt - m))) + "px";
  }
  function show(el) {
    var full = text(el);
    if (!full) return hide();
    if (target && target !== el) target.removeAttribute("aria-describedby");
    target = el;
    ensureTip().textContent = full;
    el.setAttribute("aria-describedby", "peek");
    place(el);
  }
  function hide() {
    if (target) target.removeAttribute("aria-describedby");
    target = null; touchShown = false;
    if (tip) tip.hidden = true;
  }

  document.addEventListener("pointerover", function (e) {
    if (e.pointerType === "touch") return;
    var el = findTarget(e.target);
    if (el) show(el); else if (target && !target.contains(e.target)) hide();
  });
  document.addEventListener("pointerout", function (e) {
    if (e.pointerType === "touch" || !target) return;
    if (!e.relatedTarget || !target.contains(e.relatedTarget)) hide();
  });
  document.addEventListener("focusin", function (e) { var el = findTarget(e.target); if (el) show(el); });
  document.addEventListener("focusout", function () { if (!touchShown) hide(); });
  /* touch: a tap on cut-off text shows it; the next tap anywhere hides it (the tap still works as usual) */
  document.addEventListener("pointerdown", function (e) {
    if (e.pointerType !== "touch") return;
    var el = findTarget(e.target);
    if (el && el !== target) { show(el); touchShown = true; } else hide();
  }, true);
  document.addEventListener("keydown", function (e) { if (e.key === "Escape") hide(); });
  window.addEventListener("scroll", hide, true);
  window.addEventListener("resize", hide);

  window.IslePeek = { show: show, hide: hide, isTruncated: truncated };
})();
