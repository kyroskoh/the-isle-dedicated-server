/* Applies the saved theme before first paint (no flash). "system" follows the OS live. */
(function () {
  var KEY = "isle-theme";
  function saved() { try { return localStorage.getItem(KEY) || "system"; } catch (e) { return "system"; } }
  function apply(mode) {
    if (mode === "light" || mode === "dark") document.documentElement.setAttribute("data-theme", mode);
    else document.documentElement.removeAttribute("data-theme");
  }
  apply(saved());
  window.IsleTheme = {
    get: saved,
    set: function (mode) {
      try { localStorage.setItem(KEY, mode); } catch (e) { /* private mode: not remembered */ }
      apply(mode);
    },
    /* wires a .segmented control with radios named "theme" */
    bind: function (root) {
      var radios = root.querySelectorAll('input[name="theme"]');
      function sync() {
        var cur = saved();
        radios.forEach(function (r) { r.checked = r.value === cur; r.parentNode.classList.toggle("checked", r.checked); });
      }
      radios.forEach(function (r) { r.addEventListener("change", function () { window.IsleTheme.set(r.value); sync(); }); });
      window.addEventListener("storage", function (e) { if (e.key === KEY) { apply(saved()); sync(); } });
      sync();
    }
  };
})();
