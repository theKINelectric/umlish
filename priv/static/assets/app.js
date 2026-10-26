// Umlish web client — plain JS, no build step.
//
// Tabs: Package graph (default, drill-down), Class diagram (Mermaid),
// Packages, Edges, JSON. Selection state lives in the URL hash:
//   #s=<snapshot>&p=<package>&c=<class>&path=<last scan>&scope=<scope>
// so any view — including a drill-down — is a shareable URL.

(function () {
  "use strict";

  var state = {
    document: null,
    native: null,
    mermaidReady: false,
    currentTab: "graph",
    baseURL: null,
    snapshotId: null,
    graph: null,
    pkgBySafeId: {},
    path: null,
    scope: null,
    package: null,
    cls: null,
    renderSeq: 0,
    drillSeq: 0,
  };

  var selectionSeq = 0;

  // -- mermaid from CDN (best effort; everything else works without it) ----
  function loadMermaid(cb) {
    if (window.mermaid) return cb(window.mermaid);
    var s = document.createElement("script");
    s.src = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js";
    s.onload = function () { cb(window.mermaid); };
    s.onerror = function () { cb(null); };
    document.head.appendChild(s);
  }

  function ensureMermaid(cb) {
    if (state.mermaidReady) return cb(window.mermaid);
    loadMermaid(function (m) {
      if (!m) return cb(null);
      m.initialize({ startOnLoad: false, theme: "dark", securityLevel: "loose" });
      state.mermaidReady = true;
      cb(m);
    });
  }

  // -- small helpers --------------------------------------------------------
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"\x27]/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "\x27": "&#39;" }[ch];
    });
  }

  function setStatus(text, cls) {
    var el = document.getElementById("status");
    el.textContent = text;
    // keep the base layout classes; only swap the state class
    el.className = "control-row small" + (cls ? " " + cls : "");
  }

  function fetchJSON(url, opts) {
    return fetch(url, opts).then(function (res) {
      return res.json().then(function (body) {
        if (!res.ok) {
          var msg = body && body.error && body.error.message ? body.error.message : res.status + " " + res.statusText;
          throw new Error(msg);
        }
        return body;
      });
    });
  }

  function evidenceHtml(evidence) {
    if (state.native) return (evidence || []).map(function (ev) {
      var site = state.native.sites.get(ev.file + "\0" + ev.start_byte);
      return site == null ? "" : '<button class="back-link evidence" data-native-site="' + site + '">' + esc(ev.file + ':' + ev.line) + ' · inspect source</button>';
    }).join(" ");
    var points = (evidence || []).filter(function (ev) { return ev && (ev.file || ev.line); });
    if (!points.length) return "";
    var text = points.map(function (ev) {
      var at = [ev.file, ev.line].filter(function (x) { return x != null; }).join(":");
      return esc(at);
    }).join(" · ");
    return '<div class="evidence">↳ ' + text + "</div>";
  }

  function kindChip(kind) {
    return '<span class="kind ' + esc(kind) + '">' + esc(kind) + "</span>";
  }

  // -- URL state -------------------------------------------------------------
  function updateHash() {
    if (state.native) {
      history.replaceState(null, "", window.location.pathname);
      return;
    }
    var parts = [];
    if (state.snapshotId) parts.push("s=" + state.snapshotId);
    if (state.path) parts.push("path=" + encodeURIComponent(state.path));
    if (state.scope) parts.push("scope=" + encodeURIComponent(state.scope));
    if (state.package) parts.push("p=" + encodeURIComponent(state.package));
    if (state.cls) parts.push("c=" + encodeURIComponent(state.cls));
    var hash = parts.length ? "#" + parts.join("&") : "";
    if (hash !== window.location.hash) {
      history.replaceState(null, "", window.location.pathname + hash);
    }
  }

  function readHash() {
    var out = {};
    (window.location.hash || "").replace(/^#/, "").split("&").forEach(function (kv) {
      var pair = kv.split("=");
      if (pair.length === 2) out[decodeURIComponent(pair[0])] = decodeURIComponent(pair[1]);
    });
    return out;
  }

  // -- document flow -----------------------------------------------------------
  function run(url, label, runInfo) {
    var ticket = ++selectionSeq;
    setStatus(label + " — flowing through the pipeline…", "busy");
    var buttons = [document.getElementById("btn-internals"), document.getElementById("btn-project")];
    buttons.forEach(function (b) { b.disabled = true; });

    fetchJSON(url)
      .then(function (doc) {
        if (ticket !== selectionSeq) return;
        showDocument(doc, url, runInfo);
        var meta = doc.meta || {};
        setStatus(
          label + " done — " + meta.class_count + " classes, " + meta.edge_count + " edges" +
            (meta.snapshot_id ? ", snapshot #" + meta.snapshot_id : "") + "."
        );
        refreshHistory();
      })
      .catch(function (err) {
        if (ticket === selectionSeq) setStatus(label + " failed: " + err.message, "error");
      })
      .finally(function () {
        buttons.forEach(function (b) { b.disabled = false; });
      });
  }

  function showDocument(doc, baseURL, runInfo, knownSnapshotId) {
    selectionSeq++;
    state.renderSeq++;
    state.drillSeq++;
    state.native = runInfo && runInfo.native || null;
    state.document = doc;
    state.baseURL = baseURL;
    // Fresh runs carry snapshot_id in meta; replayed documents were
    // persisted without it, so the caller passes the id it fetched by.
    state.snapshotId = state.native ? null : (doc.meta && doc.meta.snapshot_id) || knownSnapshotId || null;
    state.graph = null;
    state.pkgBySafeId = {};
    state.package = null;
    state.cls = null;
    document.getElementById("drill-panel").hidden = true;
    document.getElementById("drill-panel").innerHTML = "";
    if (runInfo) {
      state.path = runInfo.path || null;
      state.scope = runInfo.scope || null;
    }

    document.getElementById("native-notice").hidden = !state.native;
    var result = document.getElementById("result");
    result.hidden = false;

    document.getElementById("schema-title").textContent = doc.title || "UML schema";

    var chips = document.getElementById("chips");
    chips.innerHTML = "";
    function chip(label, value, cls) {
      var c = document.createElement("span");
      c.className = "chip" + (cls ? " " + cls : "");
      c.innerHTML = label + " <b></b>";
      c.querySelector("b").textContent = value;
      chips.appendChild(c);
    }
    var meta = doc.meta || {};
    chip("classes", meta.class_count != null ? meta.class_count : "?");
    chip("packages", meta.package_count != null ? meta.package_count : "?");
    chip("edges", meta.edge_count != null ? meta.edge_count : "?");
    if (meta.language) chip("lang", meta.language);
    if (meta.duration_ms != null) chip("in", meta.duration_ms + " ms");
    if (state.snapshotId) chip("snapshot", "#" + state.snapshotId);
    (doc.foreign || []).slice(0, 6).forEach(function (f) {
      chip("foreign", f.name, "foreign");
    });

    if (state.native) {
      chip("observation", state.native.input.status);
      chip("resolution", state.native.input.fully_resolved ? "selected targets resolved" : "unresolved / incomplete");
    }
    document.getElementById("link-mermaid").hidden = !!state.native;
    document.getElementById("link-json").href = baseURL;
    document.getElementById("link-mermaid").href =
      baseURL + (baseURL.indexOf("?") >= 0 ? "&" : "?") + "as=mermaid";

    renderPackages(doc);
    renderEdges(doc);
    document.getElementById("json-pre").textContent = JSON.stringify(doc, null, 2);

    activateTab("graph");
    loadGraph();
    updateHash();
    result.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  // -- tabs ----------------------------------------------------------------
  function activateTab(name) {
    state.currentTab = name;
    document.querySelectorAll(".tab").forEach(function (t) {
      t.classList.toggle("active", t.dataset.tab === name);
    });
    ["graph", "diagram", "packages", "edges", "json"].forEach(function (n) {
      var panel = document.getElementById("panel-" + n);
      if (panel) panel.hidden = n !== name;
    });
    if (name === "diagram") renderDiagram();
  }

  document.querySelectorAll(".tab").forEach(function (tab) {
    tab.addEventListener("click", function () { activateTab(tab.dataset.tab); });
  });

  // -- package graph + drill-down ----------------------------------------------
  function loadGraph() {
    if (state.native) { renderNativeGraph(); return; }
    if (!state.snapshotId) return;
    var box = document.getElementById("graph-box");
    var drill = document.getElementById("drill-panel");
    drill.hidden = true;
    drill.innerHTML = "";
    box.innerHTML = '<p class="muted small">Loading component graph…</p>';

    var ticket = selectionSeq;
    fetchJSON("/api/schemas/" + state.snapshotId + "/graph")
      .then(function (graph) {
        if (ticket !== selectionSeq || state.native) return;
        state.graph = graph;
        var bySafe = {};
        (graph.nodes || []).forEach(function (n) {
          bySafe[String(n.id).replace(/[^A-Za-z0-9_]/g, "_")] = n.id;
        });
        state.pkgBySafeId = bySafe;
        renderGraphMermaid();
      })
      .catch(function (err) {
        if (ticket !== selectionSeq || state.native) return;
        box.innerHTML = '<p class="muted">Component graph failed: ' + esc(err.message) + "</p>";
      });
  }

  function renderGraphMermaid() {
    var box = document.getElementById("graph-box");
    if (!state.graph) return;

    // Callback the flowchart nodes invoke (mermaid `call` bindings).
    window.umlPkgClick = function (safeId) {
      var pkgId = state.pkgBySafeId[safeId];
      if (pkgId) drillPackage(pkgId);
    };

    var seq = ++state.renderSeq;

    ensureMermaid(function (m) {
      if (seq !== state.renderSeq || state.native) return;
      if (!m) {
        renderGraphFallback();
        return;
      }
      fetch("/api/schemas/" + state.snapshotId + "/graph?as=mermaid")
        .then(function (r) { return r.text(); })
        .then(function (text) {
          if (seq !== state.renderSeq) return;
          return m.render("uml-pkg-" + seq, text);
        })
        .then(function (out) {
          if (out && seq === state.renderSeq) box.innerHTML = out.svg;
        })
        .catch(function (err) {
          if (seq === state.renderSeq) renderGraphFallback(err.message);
        });
    });
  }

  // Offline / mermaid-less view: plain clickable chips + edge table.
  function renderGraphFallback(errNote) {
    var g = state.graph;
    var html = "";
    if (errNote) html += '<p class="muted small">Mermaid unavailable (' + esc(errNote) + ') — plain view:</p>';

    html += '<div class="foreign-chips" style="margin:0 0 14px">';
    (g.nodes || []).forEach(function (n) {
      html += '<span class="chip clickable" data-pkg="' + esc(n.id) + '">' + esc(n.label) + " · " + n.class_count + "</span>";
    });
    html += "</div>";

    var rows = (g.edges || []).slice(0, 40).map(function (e) {
      return "<tr><td class='mono clickable' data-pkg='" + esc(e.from) + "'>" + esc(e.from) + "</td>" +
        "<td class='mono clickable' data-pkg='" + esc(e.to) + "'>" + esc(e.to) + "</td>" +
        "<td>" + e.kinds.map(kindChip).join(" ") + "</td>" +
        "<td class='mono'>" + e.pair_count + "</td></tr>";
    }).join("");

    html += "<table class='edge-table'><thead><tr><th>From</th><th>To</th><th>Kinds</th><th>Class edges</th></tr></thead><tbody>" + rows + "</tbody></table>";

    var box = document.getElementById("graph-box");
    box.innerHTML = html;
    box.querySelectorAll("[data-pkg]").forEach(function (el) {
      el.addEventListener("click", function () { drillPackage(el.dataset.pkg); });
    });
  }

  function drillPackage(pkgId) {
    if (state.native) { state.package = pkgId; state.cls = null; activateTab("graph"); renderNativePackage(pkgId); return; }
    if (!state.snapshotId) return;
    state.package = pkgId;
    state.cls = null;
    updateHash();
    activateTab("graph");

    var panel = document.getElementById("drill-panel");
    panel.hidden = false;
    panel.innerHTML = '<p class="muted small">Loading ' + esc(pkgId) + "…</p>";

    var ticket = selectionSeq, drillTicket = ++state.drillSeq;
    fetchJSON("/api/schemas/" + state.snapshotId + "/graph/" + encodeURIComponent(pkgId))
      .then(function (d) {
        if (ticket !== selectionSeq || drillTicket !== state.drillSeq || state.native) return;
        renderPackageDetail(d, pkgId);
      })
      .catch(function (err) {
        if (ticket !== selectionSeq || drillTicket !== state.drillSeq || state.native) return;
        panel.innerHTML = '<p class="muted">Drill-down failed: ' + esc(err.message) + "</p>";
      });
  }

  function renderPackageDetail(d, pkgId) {
    var panel = document.getElementById("drill-panel");
    var node = d.node;

    var foreignChips = Object.keys(d.foreign || {})
      .sort(function (a, b) { return (d.foreign[b] - d.foreign[a]); })
      .map(function (seg) {
        return '<span class="chip foreign">' + esc(seg) + " <b>" + d.foreign[seg] + "</b></span>";
      })
      .join("");

    function depList(items, dir) {
      if (!items.length) return '<p class="muted small">none</p>';
      return '<ul class="dep-list">' + items.map(function (item) {
        var other = dir === "out" ? item.to : item.from;
        var pairs = (item.pairs || []).map(function (p) {
          return '<span class="pair" data-cls="' + esc(dir === "out" ? p.from : p.to) + '">' +
            esc(p.from) + " → " + esc(p.to) + "</span>";
        }).join("");
        return '<li class="dep-item"><div class="dep-title">' +
          '<span class="clickable" data-pkg="' + esc(other) + '">' + esc(other) + "</span>" +
          item.kinds.map(kindChip).join(" ") +
          "<span class='muted'>" + item.pair_count + " class " + (item.pair_count === 1 ? "edge" : "edges") + "</span></div>" +
          '<div class="pair-list">' + pairs + "</div>" +
          evidenceHtml(item.pairs && item.pairs[0] && item.pairs[0].evidence) +
          "</li>";
      }).join("") + "</ul>";
    }

    var classRows = (d.classes || []).map(function (c) {
      var ops = (c.ops || []).map(function (op) {
        return (op.visibility === "private" ? "−" : "+") + op.name + "/" + op.arity;
      }).join("  ");
      return "<tr>" +
        '<td class="mono clickable" data-cls="' + esc(c.id) + '">' + esc(c.name) + "</td>" +
        '<td class="mono muted">' + esc(c.ns) + "</td>" +
        '<td class="mono ops">' + esc(ops) + "</td></tr>";
    }).join("");

    panel.innerHTML =
      '<div class="drill-head">' +
      "<h4>" + esc(node.label) + " <span class='muted'>(" + node.class_count + " classes)</span></h4>" +
      '<button class="back-link" id="drill-close" type="button">× close</button>' +
      "</div>" +
      (foreignChips ? '<div class="foreign-chips">' + foreignChips + "</div>" : "") +
      '<div class="drill-cols">' +
      "<div><h5>Outgoing dependencies</h5>" + depList(d.outgoing || [], "out") + "</div>" +
      "<div><h5>Incoming dependencies</h5>" + depList(d.incoming || [], "in") + "</div>" +
      "</div>" +
      "<h5>Classes</h5>" +
      "<table class='pkg-table'><thead><tr><th>Class</th><th>Namespace</th><th>Ops</th></tr></thead><tbody>" +
      classRows + "</tbody></table>";

    panel.querySelectorAll("[data-pkg]").forEach(function (el) {
      el.addEventListener("click", function () { drillPackage(el.dataset.pkg); });
    });
    panel.querySelectorAll(".pair[data-cls]").forEach(function (el) {
      el.addEventListener("click", function () { drillClass(el.dataset.cls); });
    });
    panel.querySelectorAll("td[data-cls]").forEach(function (el) {
      el.addEventListener("click", function () { drillClass(el.dataset.cls); });
    });
    document.getElementById("drill-close").addEventListener("click", function () {
      panel.hidden = true;
      panel.innerHTML = "";
      state.package = null;
      state.cls = null;
      updateHash();
    });

    panel.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  function drillClass(clsId) {
    if (state.native) { var card = state.native.clazz(clsId); if (card) { state.cls = clsId; activateTab("graph"); document.getElementById("drill-panel").hidden = false; renderClassCard(card); } return; }
    if (!state.snapshotId) return;
    state.cls = clsId;
    updateHash();
    activateTab("graph");

    var panel = document.getElementById("drill-panel");
    panel.hidden = false;
    panel.innerHTML = '<p class="muted small">Loading ' + esc(clsId) + "…</p>";

    var ticket = selectionSeq, drillTicket = ++state.drillSeq;
    fetchJSON("/api/schemas/" + state.snapshotId + "/classes/" + encodeURIComponent(clsId))
      .then(function (card) {
        if (ticket !== selectionSeq || drillTicket !== state.drillSeq || state.native) return;
        renderClassCard(card);
      })
      .catch(function (err) {
        if (ticket !== selectionSeq || drillTicket !== state.drillSeq || state.native) return;
        panel.innerHTML = '<p class="muted">Class card failed: ' + esc(err.message) + "</p>";
      });
  }

  function renderClassCard(c) {
    var panel = document.getElementById("drill-panel");
    var ops = (c.ops || []).map(function (op) {
      return (op.visibility === "private" ? "−" : "+") + op.name + "(" + (op.args || []).join(", ") + ")";
    }).join("  ");
    var fields = (c.fields || []).map(function (f) {
      return f.name + (f.type ? ":" + f.type : "");
    }).join("  ");
    var stereo = c.stereotype && c.stereotype !== "class" ? " «" + c.stereotype + "»" : "";

    function depRows(deps, dir) {
      if (!deps.length) return '<p class="muted small">none</p>';
      return '<ul class="dep-list">' + deps.map(function (d) {
        var other = dir === "out" ? d.to : d.from;
        return '<li class="dep-item"><div class="dep-title">' +
          '<span class="clickable" data-cls="' + esc(other) + '">' + esc(other) + "</span>" +
          kindChip(d.kind) + (state.native ? " " + esc(d.label) : "") + "</div>" + evidenceHtml(d.evidence) + "</li>";
      }).join("") + "</ul>";
    }

    panel.innerHTML =
      '<div class="drill-head">' +
      '<h4>Class card</h4>' +
      (state.package
        ? '<button class="back-link" id="cls-back" type="button">← back to ' + esc(state.package) + "</button>"
        : '<button class="back-link" id="cls-back" type="button">× close</button>') +
      "</div>" +
      '<div class="cls-card">' +
      "<h4>" + esc(c.name) + "<span class='muted stereo'>" + esc(stereo) + "</span></h4>" +
      '<div class="mono muted">' + esc(c.ns) + (c.file ? " · " + esc(c.file) : "") + "</div>" +
      (fields ? '<div class="cls-ops">' + esc(fields) + "</div>" : "") +
      (ops ? '<div class="cls-ops">' + esc(ops) + "</div>" : "") +
      "</div>" +
      '<div class="drill-cols">' +
      "<div><h5>Depends on</h5>" + depRows(c.outgoing || [], "out") + "</div>" +
      "<div><h5>Depended on by</h5>" + depRows(c.incoming || [], "in") + "</div>" +
      "</div>";

    panel.querySelectorAll("[data-cls]").forEach(function (el) {
      el.addEventListener("click", function () { drillClass(el.dataset.cls); });
    });
    document.getElementById("cls-back").addEventListener("click", function () {
      if (state.package) drillPackage(state.package);
      else {
        panel.hidden = true;
        panel.innerHTML = "";
        state.cls = null;
        updateHash();
      }
    });

    panel.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  // -- class diagram (Mermaid) ---------------------------------------------------
  function mermaidStatusEl(box) {
    var el = document.getElementById("mermaid-status");
    if (!el) {
      el = document.createElement("p");
      el.className = "muted";
      el.id = "mermaid-status";
      box.appendChild(el);
    }
    return el;
  }

  function renderDiagram() {
    var box = document.getElementById("mermaid-box");
    if (!state.document) return;
    if (state.native) { box.textContent = "Native import facts are shown in the local source graph; no class-member or Mermaid rendering is claimed."; return; }

    var seq = ++state.renderSeq, documentAtStart = state.document;
    ensureMermaid(function (m) {
      if (seq !== state.renderSeq || state.native || state.document !== documentAtStart) return;
      if (!m) {
        mermaidStatusEl(box).textContent =
          "Mermaid could not load (offline?). Use the Package graph / Packages / Edges tabs — fully local.";
        return;
      }
      var url = state.baseURL;
      mermaidStatusEl(box).textContent = "Rendering class diagram…";

      fetch(url + (url.indexOf("?") >= 0 ? "&" : "?") + "as=mermaid")
        .then(function (r) { return r.text(); })
        .then(function (text) {
          if (seq !== state.renderSeq) return;
          return m.render("uml-diagram-" + seq, text);
        })
        .then(function (out) {
          if (out && seq === state.renderSeq) box.innerHTML = out.svg;
        })
        .catch(function (err) {
          if (seq === state.renderSeq) {
            mermaidStatusEl(box).textContent = "Diagram failed: " + err.message;
          }
        });
    });
  }

  // -- packages table -----------------------------------------------------------
  function renderPackages(doc) {
    var panel = document.getElementById("panel-packages");
    var html = (doc.packages || []).map(function (pkg) {
      var rows = (pkg.classes || []).map(function (c) {
        var ops = (c.ops || []).map(function (op) {
          return (op.visibility === "private" ? "−" : "+") + op.name + "/" + op.arity;
        }).join("  ");
        var fields = (c.fields || []).map(function (f) {
          return f.name + (f.type ? ":" + f.type : "");
        }).join("  ");
        var stereo = c.stereotype && c.stereotype !== "class" ? " «" + c.stereotype + "»" : "";
        return "<tr>" +
          "<td class='mono clickable' data-cls='" + esc(c.id) + "'>" + esc(c.name) +
          "<span class='stereo'>" + esc(stereo) + "</span></td>" +
          "<td class='mono muted'>" + esc(c.ns) + "</td>" +
          "<td class='mono muted'>" + (c.file ? "<code class='file'>" + esc(c.file) + "</code>" : "—") + "</td>" +
          "<td class='mono ops'>" + esc(fields) + "</td>" +
          "<td class='mono ops'>" + esc(ops) + "</td>" +
          "</tr>";
      }).join("");
      return "<div class='pkg'><h4><span class='clickable' data-pkg='" + esc(pkg.id) + "'>" + esc(pkg.label || pkg.id) +
        "</span> · " + (pkg.classes || []).length + "</h4>" +
        "<table class='pkg-table'><thead><tr><th>Class</th><th>Namespace</th><th>File</th><th>Fields</th><th>Ops</th></tr></thead>" +
        "<tbody>" + rows + "</tbody></table></div>";
    }).join("");

    var foreign = doc.foreign || [];
    if (foreign.length) {
      var frows = foreign.map(function (f) {
        var count = (doc.meta && doc.meta.foreign_refs && doc.meta.foreign_refs[f.id]) || 0;
        return "<tr><td class='mono'>" + esc(f.name) + "</td><td class='mono muted'>" + esc(state.native ? f.resolution : "external") + "</td><td></td><td></td><td class='mono ops'>" + count + " references</td></tr>";
      }).join("");
      html += "<div class='pkg'><h4>" + (state.native ? "Unresolved references" : "Foreign libraries") + " · " + foreign.length + "</h4>" +
        "<table class='pkg-table'><thead><tr><th>Class</th><th>Namespace</th><th>File</th><th>Fields</th><th>Ops</th></tr></thead><tbody>" + frows + "</tbody></table></div>";
    }

    panel.innerHTML = html || "<p class='muted'>No packages.</p>";
    panel.querySelectorAll("[data-cls]").forEach(function (el) {
      el.addEventListener("click", function () { drillClass(el.dataset.cls); });
    });
    panel.querySelectorAll("[data-pkg]").forEach(function (el) {
      el.addEventListener("click", function () { drillPackage(el.dataset.pkg); });
    });
  }

  // -- edges table ------------------------------------------------------------------
  function renderEdges(doc) {
    var panel = document.getElementById("panel-edges");
    var rows = (doc.edges || []).map(function (e) {
      var ev = (e.evidence || [])[0];
      var evText = ev ? [ev.file, ev.line].filter(function (x) { return x != null; }).join(":") : "";
      return "<tr>" +
        "<td class='mono clickable' data-cls='" + esc(e.from) + "'>" + esc(e.from) + "</td>" +
        "<td class='mono clickable' data-cls='" + esc(e.to) + "'>" + esc(e.to) + "</td>" +
        "<td>" + kindChip(e.kind) + "</td>" +
        "<td class='mono muted'>" + esc(e.label || "") + "</td>" +
        "<td class='mono muted small'>" + (state.native ? evidenceHtml(e.evidence) : esc(evText)) + "</td>" +
        "</tr>";
    }).join("");

    panel.innerHTML = rows
      ? "<table class='edge-table'><thead><tr><th>From</th><th>To</th><th>Kind</th><th>Label</th><th>Evidence</th></tr></thead><tbody>" + rows + "</tbody></table>"
      : "<p class='muted'>No edges.</p>";
    panel.querySelectorAll("[data-cls]").forEach(function (el) {
      el.addEventListener("click", function () { drillClass(el.dataset.cls); });
    });
  }

  // -- history -----------------------------------------------------------------
  function refreshHistory() {
    fetchJSON("/api/schemas")
      .then(function (body) {
        var list = document.getElementById("history");
        var items = body.data || [];
        if (!items.length) {
          list.innerHTML = "<p class='muted'>Nothing yet — run the internals or a project scan.</p>";
          return;
        }
        list.innerHTML = "";
        items.forEach(function (s) {
          var el = document.createElement("div");
          el.className = "history-item";
          el.innerHTML =
            "<span class='h-title'>#" + s.id + " " + esc(s.title) + "</span>" +
            "<span class='h-meta'>" + esc(s.kind) + " · " + esc(s.language) + " · " +
            s.class_count + " classes · " + s.edge_count + " edges · " + s.duration_ms + " ms · " +
            esc((s.inserted_at || "").replace("T", " ").replace("Z", "")) + "</span>";
          el.addEventListener("click", function () {
            var ticket = ++selectionSeq;
            fetchJSON("/api/schemas/" + s.id)
              .then(function (doc) {
                if (ticket !== selectionSeq) return;
                state.path = s.project_path;
                state.scope = null;
                showDocument(doc, "/api/schemas/" + s.id, null, s.id);
                setStatus("Replaying snapshot #" + s.id + ".");
              })
              .catch(function (err) {
                if (ticket === selectionSeq) setStatus("Replay failed: " + err.message, "error");
              });
          });
          list.appendChild(el);
        });
      })
      .catch(function () {
        document.getElementById("history").innerHTML = "<p class='muted'>History unavailable.</p>";
      });
  }


  // Native imports stay in browser memory. No service scan or persistence.
  function renderNativeGraph() {
    var model = state.native, all = Array.from(model.nodes.values()), visible = all.slice(0, 60);
    var positions = new Map(), width = 1000, height = Math.max(160, Math.ceil(visible.length / 4) * 110 + 80);
    visible.forEach(function (n, i) { positions.set(n.id, {x: 20 + (i % 4) * 245, y: 70 + Math.floor(i / 4) * 110}); });
    var drawable = model.input.imports.map(function (f, i) { return {fact: f, site: i}; })
      .filter(function (s) { return positions.has(s.fact.from) && positions.has(s.fact.to); }).slice(0, 200);
    var html = '<svg class="native-graph" viewBox="0 0 ' + width + ' ' + height + '" aria-label="Observed source imports">' +
      '<defs><marker id="native-arrow" markerUnits="userSpaceOnUse" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8" fill="#a7b5cf"/></marker></defs>';
    drawable.forEach(function (s) {
      var from = positions.get(s.fact.from), to = positions.get(s.fact.to);
      var x1 = from.x + 110, y1 = from.y + 38, x2 = to.x + 110, y2 = to.y + 38;
      var curve;
      if (s.fact.from === s.fact.to) {
        // Reserve space above each row; endpoints stay outside the opaque node.
        curve = 'M' + (from.x + 170) + ',' + (from.y - 6) + ' C' +
          (from.x + 200) + ',' + (from.y - 60) + ' ' + (from.x + 20) + ',' + (from.y - 60) + ' ' +
          (from.x + 50) + ',' + (from.y - 6);
      } else {
        var dx = x2 - x1, dy = y2 - y1;
        var boundary = Math.min(116 / Math.abs(dx), 44 / Math.abs(dy));
        curve = 'M' + (x1 + dx * boundary) + ',' + (y1 + dy * boundary) +
          ' L' + (x2 - dx * boundary) + ',' + (y2 - dy * boundary);
      }
      html += '<path class="native-edge" d="' + curve + '" data-native-site="' + s.site +
        '" role="button" tabindex="0" aria-label="' + esc(s.fact.path + ':' + s.fact.line + ' ' + s.fact.expression) +
        '" marker-end="url(#native-arrow)"><title>' + esc(s.fact.expression + ' · ' + s.fact.resolution) + '</title></path>';
    });
    visible.forEach(function (n) {
      var p = positions.get(n.id), label = n.name.length > 26 ? n.name.slice(0, 23) + '…' : n.name;
      html += '<g data-cls="' + esc(n.id) + '" class="native-node" role="button" tabindex="0" transform="translate(' +
        p.x + ',' + p.y + ')"><title>' + esc(n.ns) + '</title><rect width="220" height="76" rx="9"/>' +
        '<text x="12" y="29">' + esc(label) + '</text><text x="12" y="52" class="native-subtitle">' +
        esc(n.file ? (n.profile_complete ? 'selected source' : 'incomplete source') : n.resolution) + '</text></g>';
    });
    html += '</svg>';
    var box = document.getElementById("graph-box"); box.innerHTML = html;
    box.querySelectorAll("[data-cls]").forEach(function (el) {
      el.addEventListener("click", function () { drillClass(el.dataset.cls); });
      el.addEventListener("keydown", function (ev) { if (ev.key === "Enter" || ev.key === " ") { ev.preventDefault(); drillClass(el.dataset.cls); } });
    });
    document.getElementById("graph-status").textContent =
      "Observed source imports — " + visible.length + "/" + all.length + " nodes and " + drawable.length + "/" +
      model.input.imports.length + " relationships drawn. All admitted sites remain in Edges. Directory groups are presentation; unresolved targets are not external deployment.";
  }

  function renderNativePackage(pkgId) {
    var model = state.native, pkg = model.groups.get(pkgId);
    if (!pkg) return;
    var members = new Set(pkg.classes.map(function (c) { return c.id; }));
    var sites = model.input.imports.map(function (f, i) { return {fact:f, site:i}; })
      .filter(function (s) { return members.has(s.fact.from) || members.has(s.fact.to); });
    var panel = document.getElementById("drill-panel"); panel.hidden = false;
    panel.innerHTML = '<h4>Directory ' + esc(pkg.label) + '</h4><p class="muted">Presentation grouping, not runtime ownership.</p>' +
      pkg.classes.map(function (c) { return '<button class="btn small" data-cls="' + esc(c.id) + '">' + esc(c.file) + '</button>'; }).join(" ") +
      '<h5>Import sites involving this directory · ' + sites.length + '</h5>' +
      sites.map(function (s) { return evidenceHtml(model.document.edges[s.site].evidence); }).join("");
    panel.querySelectorAll("[data-cls]").forEach(function (el) {
      el.addEventListener("click", function () { drillClass(el.dataset.cls); });
    });
  }

  function showNativeEvidence(site) {
    var model = state.native;
    if (!model || !Number.isSafeInteger(site) || !model.input.imports[site]) return;
    activateTab("graph");
    var fact = model.input.imports[site], panel = document.getElementById("drill-panel");
    panel.hidden = false;
    panel.innerHTML = '<h4>Captured source evidence</h4><p class="mono">' + esc(fact.path + ':' + fact.line) +
      ' · bytes [' + fact.start_byte + ', ' + fact.end_byte + ')</p><p>' + esc(fact.resolution) +
      '</p><pre id="native-expression" class="json-pre">' + esc(fact.expression) +
      '</pre><p class="mono small">SHA256 ' + esc(fact.source_sha256) +
      '</p><label class="btn small">Verify selected source bytes <input id="native-source" type="file"/></label>' +
      '<p id="native-verification" role="status">Captured observation; selected source bytes have not been checked.</p>';
    var verifyInput = panel.querySelector("#native-source"), message = panel.querySelector("#native-verification"), attempt = 0;
    verifyInput.addEventListener("change", async function () {
      var token = ++attempt, file = verifyInput.files[0];
      if (!file) return;
      message.textContent = "Checking selected bytes…";
      try {
        if (file.size > window.UmlishNative.limits.sourceBytes) throw new Error("Source exceeds 1 MiB verification admission");
        await model.verify(site, new Uint8Array(await file.arrayBuffer()));
        if (token !== attempt || state.native !== model || !message.isConnected) return;
        message.textContent = "Verified: selected bytes match the snapshot digest, expression span and line. This does not reanalyse Zig semantics.";
        message.className = "success";
      } catch (err) {
        if (token !== attempt || state.native !== model || !message.isConnected) return;
        message.textContent = "Verification failed: " + err.message; message.className = "error";
      }
    });
    panel.scrollIntoView({behavior:"smooth", block:"nearest"});
  }

  document.addEventListener("click", function (ev) {
    var point = ev.target.closest("[data-native-site]");
    if (point) showNativeEvidence(Number(point.dataset.nativeSite));
  });
  document.addEventListener("keydown", function (ev) {
    var point = ev.target.closest("[data-native-site]");
    if (point && (ev.key === "Enter" || ev.key === " ")) { ev.preventDefault(); showNativeEvidence(Number(point.dataset.nativeSite)); }
  });
  var nativeInput = document.getElementById("input-native"), localURL = null;
  if (nativeInput) nativeInput.addEventListener("change", async function () {
    var file = nativeInput.files[0], ticket = ++selectionSeq;
    if (!file) return;
    setStatus("Opening local source graph…", "busy");
    try {
      if (!window.UmlishNative) throw new Error("Native adapter unavailable");
      if (file.size > window.UmlishNative.limits.jsonBytes) throw new Error("JSON exceeds 2 MiB viewer admission");
      var text = await file.text(), model = await window.UmlishNative.prepare(text);
      if (ticket !== selectionSeq) return;
      if (localURL) URL.revokeObjectURL(localURL);
      localURL = URL.createObjectURL(new Blob([text], {type:"application/json"}));
      showDocument(model.document, localURL, {native:model});
      document.getElementById("native-notice").textContent =
        "Local source observation · " + model.input.status + " · " + (model.input.fully_resolved ? "selected targets resolved" : "unresolved or incomplete") +
        ". Not saved to service history; reload requires reopening the JSON. " +
        model.input.issues.map(function (i) { return i.path + ": " + i.reason; }).join(" · ");
      setStatus("Opened local graph — " + model.input.files.length + " source files, " + model.input.imports.length +
        " import sites. Source bytes can be checked from each relationship.");
    } catch (err) {
      if (ticket !== selectionSeq) return;
      setStatus("Local graph refused: " + err.message + ". Previous document retained.", "error");
    }
  });

  // -- wire up -------------------------------------------------------------------
  document.getElementById("btn-internals").addEventListener("click", function () {
    run("/api/internals", "Introspection", { path: null, scope: null });
  });

  document.getElementById("form-project").addEventListener("submit", function (ev) {
    ev.preventDefault();
    var path = document.getElementById("input-path").value.trim();
    if (!path) {
      setStatus("Give me a directory first.", "error");
      return;
    }
    var url = "/api/uml?path=" + encodeURIComponent(path);
    if (state.scope === "all") url += "&scope=all";
    run(url, "Scan of " + path, { path: path, scope: state.scope });
  });

  // The agent section's stated base URL is this instance's own origin.
  var baseEl = document.querySelector(".base-url");
  if (baseEl) baseEl.textContent = window.location.origin;

  // An owned standalone export can use the same UI without a service backend.
  if (document.body.dataset.nativeOnly === "true") {
    document.getElementById("btn-internals").disabled = true;
    document.getElementById("btn-project").disabled = true;
    document.querySelector(".history").hidden = true;
    document.querySelector(".agent-api").hidden = true;
    document.querySelector(".mast-nav").hidden = true;
    document.getElementById("btn-internals").closest(".control-row").hidden = true;
    document.getElementById("form-project").closest(".control-row").hidden = true;
    document.querySelector(".tagline").textContent = "Explore selected source relationships · open an import to inspect its evidence";
    document.querySelector(".footer span").textContent = "UMLish · local source observations · imports stay in this browser; reopen the JSON after reload.";
    setStatus("Open a HoneyBadger source graph. Local imports stay in this browser.");
    return;
  }
  // scope=all comes in via the URL (hash), reflected on later form runs
  var initial = readHash();
  if (initial.scope === "all") state.scope = "all";

  if (initial.s) {
    var restoreTicket = ++selectionSeq;
    // Restore a shared view: replay the snapshot, then any drill-down.
    fetchJSON("/api/schemas/" + initial.s)
      .then(function (doc) {
        if (restoreTicket !== selectionSeq) return;
        state.path = initial.path || (doc.meta || {}).project_path || null;
        state.scope = initial.scope || null;
        showDocument(doc, "/api/schemas/" + initial.s, null, Number(initial.s));
        setStatus("Replayed snapshot #" + initial.s + " from the URL.");
        if (initial.c) drillClass(initial.c);
        else if (initial.p) drillPackage(initial.p);
      })
      .catch(function (err) {
        if (restoreTicket !== selectionSeq) return;
        setStatus("Restore failed: " + err.message, "error");
        refreshHistory();
      });
  } else if (initial.path) {
    var url = "/api/uml?path=" + encodeURIComponent(initial.path);
    if (initial.scope === "all") url += "&scope=all";
    run(url, "Scan of " + initial.path, { path: initial.path, scope: initial.scope || null });
  } else {
    refreshHistory();
  }
})();
