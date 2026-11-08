/* /docs - renders /openapi.json with a "Try it" form per operation. No external assets. */
(function () {
  "use strict";
  var TOKEN_KEY = "isle-token";
  var spec = null;

  function h(tag, attrs) {
    var el = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      var v = attrs[k];
      if (v === null || v === undefined || v === false) return;
      if (k === "text") el.textContent = v;
      else if (k === "class") el.className = v;
      else if (k === "value") el.value = v;
      else if (k === "on") Object.keys(v).forEach(function (e) { el.addEventListener(e, v[e]); });
      else el.setAttribute(k, v === true ? "" : v);
    });
    for (var i = 2; i < arguments.length; i++) {
      var c = arguments[i];
      if (c === null || c === undefined || c === false) continue;
      (Array.isArray(c) ? c : [c]).forEach(function (x) { if (x) el.appendChild(typeof x === "string" ? document.createTextNode(x) : x); });
    }
    return el;
  }
  function token() { try { return sessionStorage.getItem(TOKEN_KEY) || ""; } catch (e) { return ""; } }

  function resolve(schema, depth) {
    depth = depth || 0;
    if (!schema || depth > 6) return schema;
    if (schema.$ref) return resolve(spec.components.schemas[schema.$ref.split("/").pop()], depth + 1);
    var out = {};
    Object.keys(schema).forEach(function (k) {
      var v = schema[k];
      if (k === "properties") { out[k] = {}; Object.keys(v).forEach(function (p) { out[k][p] = resolve(v[p], depth + 1); }); }
      else if (k === "items" || k === "additionalProperties") out[k] = typeof v === "object" ? resolve(v, depth + 1) : v;
      else out[k] = v;
    });
    return out;
  }
  function example(schema, depth) {
    schema = resolve(schema);
    depth = depth || 0;
    if (!schema || depth > 5) return null;
    if (schema["enum"]) return schema["enum"][0];
    var t = Array.isArray(schema.type) ? schema.type[0] : schema.type;
    if (t === "object") {
      var o = {};
      Object.keys(schema.properties || {}).forEach(function (k) { o[k] = example(schema.properties[k], depth + 1); });
      if (!schema.properties && schema.additionalProperties) o.KEY = example(schema.additionalProperties, depth + 1);
      return o;
    }
    if (t === "array") return schema.items ? [example(schema.items, depth + 1)] : [];
    if (t === "boolean") return true;
    if (t === "integer" || t === "number") return schema["default"] !== undefined ? schema["default"] : 0;
    if (schema.pattern && schema.pattern.indexOf("7656119") >= 0) return "76561198000000000";
    return "string";
  }
  function schemaBlock(title, schema) {
    return h("details", null, h("summary", { text: title }), h("pre", { class: "output", text: JSON.stringify(resolve(schema), null, 2) }));
  }

  function operation(path, method, op) {
    var params = op.parameters || [];
    var needsAuth = !(op.security && op.security.length === 0);
    var summary = h("summary", null, h("span", { class: "method " + method, text: method.toUpperCase() }), pathWithBreaks(path),
      needsAuth ? h("span", { class: "lock", title: "Needs the Bearer token" }, svgUse("i-lock")) : null, h("span", { class: "sum", text: op.summary || "" }));
    var body = h("div", { class: "op-body" });
    var details = h("details", { class: "op", id: op.operationId }, summary, body);
    details.dataset.search = (method + " " + path + " " + (op.summary || "") + " " + op.operationId + " " + (op.tags || []).join(" ")).toLowerCase();
    var built = false;
    details.addEventListener("toggle", function () {
      if (!details.open || built) return;
      built = true;
      body.appendChild(h("p", null, h("strong", { text: op.summary || "" }), " ", h("code", { class: "muted", text: op.operationId })));
      if (op.description) body.appendChild(h("p", { class: "muted", text: op.description }));
      var inputs = {};
      var form = h("form", { class: "stack" });
      if (params.length) {
        var grid = h("div", { class: "grid cols-2" });
        params.forEach(function (p) {
          var id = op.operationId + "-" + p.name;
          var input;
          if (p.schema && p.schema["enum"]) {
            input = h("select", { id: id }, p.schema["enum"].map(function (v) { return h("option", { value: v, text: v }); }));
          } else {
            input = h("input", { id: id, type: "text", required: p.required, spellcheck: "false",
              placeholder: p.schema && p.schema["default"] !== undefined ? String(p.schema["default"]) : (p.schema && p.schema.pattern ? p.schema.pattern : "") });
          }
          inputs[p.name] = { el: input, where: p["in"] };
          grid.appendChild(h("div", { class: "field" }, h("label", { for: id }, p.name, " ", h("span", { class: "badge", text: p["in"] }), p.required ? " *" : ""), input));
        });
        form.appendChild(grid);
      }
      var bodyInput = null;
      if (op.requestBody) {
        var schema = op.requestBody.content["application/json"].schema;
        bodyInput = h("textarea", { id: op.operationId + "-body", spellcheck: "false", "aria-label": "Request body (JSON)" });
        bodyInput.value = JSON.stringify(example(schema), null, 2);
        form.appendChild(h("div", { class: "field" }, h("label", { for: bodyInput.id, text: "Request body (application/json)" }), bodyInput));
        form.appendChild(schemaBlock("Request schema", schema));
      }
      var responses = h("div", { class: "stack" }, h("h3", { text: "Responses" }));
      Object.keys(op.responses).forEach(function (code) {
        var r = op.responses[code];
        var content = r.content ? r.content[Object.keys(r.content)[0]] : null;
        responses.appendChild(content && content.schema ? schemaBlock(code + " - " + r.description + " (" + Object.keys(r.content)[0] + ")", content.schema)
          : h("p", { class: "small" }, h("code", { text: code }), " " + r.description));
      });
      var send = h("button", { class: "btn primary", type: "submit", text: "Send request" });
      var out = h("pre", { class: "output", hidden: true, "aria-live": "polite", tabindex: "0" });
      var curl = h("pre", { class: "output small", hidden: true });
      var danger = method !== "get";
      form.appendChild(h("div", { class: "row" }, send, danger ? h("span", { class: "muted small", text: "This changes the server." }) : null));
      form.addEventListener("submit", function (ev) {
        ev.preventDefault();
        if (danger && !window.confirm(method.toUpperCase() + " " + path + " changes the server. Send it?")) return;
        var url = path, query = [];
        Object.keys(inputs).forEach(function (name) {
          var v = inputs[name].el.value.trim();
          if (inputs[name].where === "path") url = url.replace("{" + name + "}", encodeURIComponent(v));
          else if (v) query.push(encodeURIComponent(name) + "=" + encodeURIComponent(v));
        });
        if (query.length) url += "?" + query.join("&");
        var opts = { method: method.toUpperCase(), headers: { Accept: "application/json" }, cache: "no-store" };
        if (needsAuth && token()) opts.headers.Authorization = "Bearer " + token();
        if (bodyInput && bodyInput.value.trim()) {
          try { JSON.parse(bodyInput.value); } catch (e) { out.hidden = false; out.textContent = "The request body is not valid JSON: " + e.message; return; }
          opts.headers["Content-Type"] = "application/json"; opts.body = bodyInput.value;
        }
        curl.hidden = false;
        curl.textContent = "curl -X " + opts.method + " " + (needsAuth ? "-H 'Authorization: Bearer $TOKEN' " : "") +
          (opts.body ? "-H 'Content-Type: application/json' -d '" + opts.body.replace(/\s+/g, " ") + "' " : "") + "'" + location.origin + url + "'";
        send.setAttribute("aria-busy", "true"); send.disabled = true;
        var started = Date.now();
        fetch(url, opts).then(function (res) {
          return res.text().then(function (text) {
            var pretty = text;
            try { pretty = JSON.stringify(JSON.parse(text), null, 2); } catch (e) { /* not JSON */ }
            out.hidden = false;
            out.textContent = "HTTP " + res.status + " " + res.statusText + "  (" + (Date.now() - started) + " ms, request " + (res.headers.get("X-Request-ID") || "?") + ")\n\n" + (pretty || "(empty body)");
          });
        }, function (e) { out.hidden = false; out.textContent = "Request failed: " + e.message; })
          .finally(function () { send.removeAttribute("aria-busy"); send.disabled = false; });
      });
      body.appendChild(h("section", { class: "stack" }, h("h3", { text: "Try it" }), form, curl, out));
      body.appendChild(responses);
    });
    return details;
  }
  // break long paths after "/" rather than inside a word
  function pathWithBreaks(path) {
    var span = h("span", { class: "path" });
    path.split("/").forEach(function (part, i) {
      if (i) { span.appendChild(document.createTextNode("/")); span.appendChild(document.createElement("wbr")); }
      span.appendChild(document.createTextNode(part));
    });
    return span;
  }
  function svgUse(id) {
    var svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("aria-hidden", "true"); svg.setAttribute("width", "14"); svg.setAttribute("height", "14");
    var use = document.createElementNS("http://www.w3.org/2000/svg", "use");
    use.setAttribute("href", "#" + id); svg.appendChild(use);
    return svg;
  }

  function render() {
    document.getElementById("api-version").textContent = "OpenAPI " + spec.openapi + " · v" + spec.info.version;
    document.getElementById("api-description").textContent = spec.info.description;
    var ops = document.getElementById("ops");
    while (ops.firstChild) ops.removeChild(ops.firstChild);
    var byTag = {};
    Object.keys(spec.paths).forEach(function (path) {
      Object.keys(spec.paths[path]).forEach(function (method) {
        var op = spec.paths[path][method];
        var tag = (op.tags || ["Other"])[0];
        (byTag[tag] = byTag[tag] || []).push(operation(path, method, op));
      });
    });
    (spec.tags || []).map(function (t) { return t.name; }).concat(Object.keys(byTag)).filter(function (t, i, a) { return a.indexOf(t) === i && byTag[t]; })
      .forEach(function (tag) {
        var sec = h("section", { class: "tag-section", "aria-labelledby": "tag-" + tag }, h("h2", { class: "tag-head", id: "tag-" + tag, text: tag }), byTag[tag]);
        ops.appendChild(sec);
      });
    if (location.hash) { var target = document.getElementById(location.hash.slice(1)); if (target) { target.open = true; target.scrollIntoView(); } }
  }

  function init() {
    window.IsleTheme.bind(document.getElementById("theme-switch"));
    var input = document.getElementById("docs-token"), stateEl = document.getElementById("auth-state");
    var showState = function () { stateEl.textContent = token() ? "A token is set for this tab - “Try it” sends it as a Bearer token." : "No token set - only /health works without one."; };
    showState();
    document.getElementById("auth-form").addEventListener("submit", function (e) {
      e.preventDefault();
      try { if (input.value.trim()) sessionStorage.setItem(TOKEN_KEY, input.value.trim()); else sessionStorage.removeItem(TOKEN_KEY); } catch (err) { /* ignore */ }
      input.value = ""; showState();
    });
    document.getElementById("op-filter").addEventListener("input", function (e) {
      var q = e.target.value.trim().toLowerCase();
      document.querySelectorAll(".op").forEach(function (d) { d.hidden = q && d.dataset.search.indexOf(q) < 0; });
      document.querySelectorAll(".tag-section").forEach(function (s) { s.hidden = !s.querySelector(".op:not([hidden])"); });
    });
    fetch("/openapi.json", { cache: "no-cache" }).then(function (r) { return r.json(); }).then(function (s) { spec = s; render(); }, function () {
      document.getElementById("ops").textContent = "Could not load /openapi.json.";
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
