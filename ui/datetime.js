/* Date/time display for the web UI: time zone (server / this browser / UTC) and date format,
   remembered per browser. Times from the API are UTC (ISO 8601 "Z"); they are converted here. */
(function () {
  "use strict";
  var TZ_KEY = "isle-tz", FMT_KEY = "isle-datefmt";
  var MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  var PRESETS = [
    { id: "dd MMM yyyy, HH:mm:ss", label: "08 Nov 2026, 14:30:05" },
    { id: "d MMM yyyy, h:mm a", label: "8 Nov 2026, 2:30 PM" },
    { id: "MMM d, yyyy h:mm:ss a", label: "Nov 8, 2026 2:30:05 PM" },
    { id: "EEE, dd MMM yyyy HH:mm", label: "Sun, 08 Nov 2026 14:30" },
    { id: "dd MMM yyyy HH:mm:ss ZZ", label: "08 Nov 2026 14:30:05 UTC+08:00" },
    { id: "yyyy-MM-dd HH:mm:ss", label: "2026-11-08 14:30:05 (ISO)" },
    { id: "dd/MM/yyyy HH:mm:ss", label: "08/11/2026 14:30:05" },
    { id: "MM/dd/yyyy hh:mm:ss a", label: "11/08/2026 02:30:05 PM" }
  ];
  var DEFAULT_FMT = PRESETS[0].id;
  var server = { offset: null, zone: null };   // from /api/v1/status

  function read(key, fallback) { try { return localStorage.getItem(key) || fallback; } catch (e) { return fallback; } }
  function write(key, value) { try { localStorage.setItem(key, value); } catch (e) { /* private mode: not remembered */ } }
  function pad(n, w) { n = String(n); while (n.length < (w || 2)) n = "0" + n; return n; }
  function zoneLabel(offset) {
    if (offset === 0) return "UTC";
    var a = Math.abs(offset);
    return "UTC" + (offset < 0 ? "-" : "+") + pad(Math.floor(a / 60)) + ":" + pad(a % 60);
  }

  /* zone: "server" | "browser" | "utc" -> { offset (minutes east of UTC, null = browser), label } */
  function zoneInfo(zone) {
    zone = zone || read(TZ_KEY, "server");
    if (zone === "utc") return { offset: 0, label: "UTC" };
    if (zone === "server" && server.offset !== null) return { offset: server.offset, label: server.zone || zoneLabel(server.offset) };
    return { offset: null, label: zoneLabel(-new Date().getTimezoneOffset()) + " (this browser)" };
  }

  var TOKENS = /'[^']*'|yyyy|yy|MMMM|MMM|MM|M|dd|d|EEEE|EEE|HH|H|hh|h|mm|ss|a|ZZ/g;
  function format(value, pattern, zone) {
    var date = value instanceof Date ? value : new Date(value);
    if (value === null || value === undefined || value === "" || isNaN(date)) return value ? String(value) : "–";
    var z = zoneInfo(zone);
    var useUtc = z.offset !== null;
    var d = useUtc ? new Date(date.getTime() + z.offset * 60000) : date;
    var p = {
      y: useUtc ? d.getUTCFullYear() : d.getFullYear(), M: useUtc ? d.getUTCMonth() : d.getMonth(),
      d: useUtc ? d.getUTCDate() : d.getDate(), w: useUtc ? d.getUTCDay() : d.getDay(),
      H: useUtc ? d.getUTCHours() : d.getHours(), m: useUtc ? d.getUTCMinutes() : d.getMinutes(),
      s: useUtc ? d.getUTCSeconds() : d.getSeconds()
    };
    var label = useUtc ? zoneLabel(z.offset) : zoneLabel(-date.getTimezoneOffset());
    return (pattern || read(FMT_KEY, DEFAULT_FMT)).replace(TOKENS, function (t) {
      switch (t) {
        case "yyyy": return String(p.y);
        case "yy": return pad(p.y % 100);
        case "MMMM": return MONTHS[p.M];
        case "MMM": return MONTHS[p.M].slice(0, 3);
        case "MM": return pad(p.M + 1);
        case "M": return String(p.M + 1);
        case "dd": return pad(p.d);
        case "d": return String(p.d);
        case "EEEE": return DAYS[p.w];
        case "EEE": return DAYS[p.w].slice(0, 3);
        case "HH": return pad(p.H);
        case "H": return String(p.H);
        case "hh": return pad(p.H % 12 || 12);
        case "h": return String(p.H % 12 || 12);
        case "mm": return pad(p.m);
        case "ss": return pad(p.s);
        case "a": return p.H < 12 ? "AM" : "PM";
        case "ZZ": return label;
        default: return t.slice(1, -1);   // 'quoted literal'
      }
    });
  }

  window.IsleTime = {
    PRESETS: PRESETS, DEFAULT_FMT: DEFAULT_FMT,
    format: format,
    zoneInfo: zoneInfo,
    zoneLabel: zoneLabel,
    getZone: function () { return read(TZ_KEY, "server"); },
    getFormat: function () { return read(FMT_KEY, DEFAULT_FMT); },
    setZone: function (z) { write(TZ_KEY, z); },
    setFormat: function (f) { write(FMT_KEY, f || DEFAULT_FMT); },
    setServer: function (offsetMinutes, zone) { server.offset = typeof offsetMinutes === "number" ? offsetMinutes : null; server.zone = zone || null; },
    /* full, unambiguous form for tooltips: 2026-11-08 14:30:05 UTC+08:00 */
    full: function (value, zone) { return format(value, "yyyy-MM-dd HH:mm:ss ZZ", zone); }
  };
})();
