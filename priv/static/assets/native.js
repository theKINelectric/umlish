// HoneyBadger source observations in the existing UMLish browser. No network I/O.
(function (root) {
  "use strict";
  const LIMITS = Object.freeze({ jsonBytes: 2097152, files: 512, imports: 2048, sourceBytes: 1048576 });
  const resolutions = new Set(["selected_file", "named_unresolved", "computed_unresolved",
    "invalid_literal", "invalid_arguments", "invalid_path", "outside_root", "not_in_snapshot"]);
  const encoder = new TextEncoder();
  function requireFact(ok, message) { if (!ok) throw new Error(message); }
  function integer(n, min, max) { return Number.isSafeInteger(n) && n >= min && n <= max; }
  function path(p) {
    return typeof p === "string" && p.length > 0 && !p.includes("\\") && !p.includes("\0") &&
      p.split("/").every(s => s.length > 0 && s !== "." && s !== "..");
  }
  function rawBytes(value) { return Array.isArray(value) && value.length <= LIMITS.sourceBytes && value.every(b => integer(b, 0, 255)); }
  function display(value) { return rawBytes(value) ? "bytes [" + value.map(b => b.toString(16).padStart(2, "0")).join(" ") + "]" : value; }
  function digest(s) { return typeof s === "string" && /^[a-f0-9]{64}$/.test(s); }
  async function sha(bytes) {
    requireFact(root.crypto && root.crypto.subtle, "Source verification needs a secure browser context");
    return Array.from(new Uint8Array(await root.crypto.subtle.digest("SHA-256", bytes)),
      b => b.toString(16).padStart(2, "0")).join("");
  }
  async function id(kind, key) { return kind + "_" + await sha(encoder.encode(kind + "\0" + key)); }
  async function referenceId(fact) {
    const prefix = encoder.encode("reference\0" + fact.resolution + "\0");
    const key = fact.literal === null
      ? encoder.encode(fact.path + "\0" + fact.start_byte + "\0" + fact.expression)
      : rawBytes(fact.literal) ? new Uint8Array(fact.literal) : encoder.encode(fact.target_path === null ? fact.literal : fact.target_path);
    const bytes = new Uint8Array(prefix.length + key.length); bytes.set(prefix); bytes.set(key, prefix.length);
    return "reference_" + await sha(bytes);
  }
  function freeze(value) {
    if (value && typeof value === "object" && !Object.isFrozen(value)) {
      Object.values(value).forEach(freeze); Object.freeze(value);
    }
    return value;
  }
  function byteOrder(a, b) {
    const l = encoder.encode(a.path), r = encoder.encode(b.path);
    for (let i = 0; i < Math.min(l.length, r.length); i++) if (l[i] !== r[i]) return l[i] - r[i];
    return l.length - r.length;
  }
  async function prepare(text) {
    requireFact(typeof text === "string" && encoder.encode(text).length <= LIMITS.jsonBytes, "JSON exceeds 2 MiB viewer admission");
    const input = JSON.parse(text);
    requireFact(input && input.version === "honeybadger.architecture.v1" &&
      input.profile === "zig-0.16-imports.v1" && input.parser === "std.zig.Ast/0.16.0", "Unsupported native source profile");
    requireFact(["complete", "partial"].includes(input.status), "Native result is unavailable or refused");
    requireFact(Array.isArray(input.files) && input.files.length > 0 && input.files.length <= LIMITS.files &&
      Array.isArray(input.imports) && input.imports.length <= LIMITS.imports &&
      Array.isArray(input.issues) && input.issues.length <= 8192, "Native result exceeds viewer admission or lacks facts");
    requireFact(typeof input.root === "string" && input.root.startsWith("/"), "Invalid declared source root");
    const snapshot = input.snapshot;
    requireFact(snapshot && typeof snapshot.title === "string" && snapshot.direction === "tb" && Array.isArray(snapshot.packages) && Array.isArray(snapshot.foreign) &&
      Array.isArray(snapshot.edges) && snapshot.edges.length === input.imports.length &&
      snapshot.packages.length <= LIMITS.files && snapshot.foreign.length <= LIMITS.imports, "Invalid graph shape");
    const files = new Map(), nodes = new Map(), groups = new Map();
    let total = 0;
    for (const file of input.files) {
      requireFact(file && path(file.path) && digest(file.sha256) &&
        integer(file.bytes, 0, LIMITS.sourceBytes) && typeof file.profile_complete === "boolean" &&
        !files.has(file.path), "Invalid or duplicate selected file");
      files.set(file.path, file); total += file.bytes;
    }
    requireFact(total === input.source_bytes && total <= 16777216, "Source-byte accounting mismatch");
    const manifestText = input.files.slice().sort(byteOrder).map(f => f.path + "\0" + f.sha256 + "\0").join("");
    requireFact(await sha(encoder.encode(manifestText)) === input.source_manifest_sha256, "Source manifest mismatch");
    for (const pkg of snapshot.packages) {
      requireFact(pkg && typeof pkg.label === "string" && Array.isArray(pkg.classes) &&
        pkg.classes.length > 0 && !groups.has(pkg.id) && pkg.id === await id("package", pkg.label), "Invalid package identity");
      groups.set(pkg.id, pkg);
      for (const cls of pkg.classes) {
        const file = cls && files.get(cls.file);
        const parent = cls && typeof cls.file === "string" && cls.file.includes("/") ? cls.file.slice(0, cls.file.lastIndexOf("/")) : ".";
        requireFact(file && cls.id === await id("file", cls.file) && cls.ns === cls.file &&
          cls.name === cls.file.split("/").pop() && cls.package_id === pkg.id && parent === pkg.label &&
          cls.profile_complete === file.profile_complete && cls.lang === "zig" && cls.stereotype === null && !nodes.has(cls.id) &&
          Array.isArray(cls.fields) && cls.fields.length === 0 && Array.isArray(cls.ops) && cls.ops.length === 0,
          "Invalid selected-file node identity");
        nodes.set(cls.id, cls);
      }
    }
    requireFact(nodes.size === files.size, "Selected file is missing from graph");
    for (const ref of snapshot.foreign) {
      requireFact(ref && typeof ref.id === "string" && /^reference_[a-f0-9]{64}$/.test(ref.id) &&
        (typeof ref.name === "string" || rawBytes(ref.name)) && (typeof ref.ns === "string" || rawBytes(ref.ns)) && resolutions.has(ref.resolution) &&
        ref.resolution !== "selected_file" && ref.file === null && ref.package_id === null &&
        ref.profile_complete === false && ref.lang === "zig" && ref.stereotype === null &&
        Array.isArray(ref.fields) && ref.fields.length === 0 && Array.isArray(ref.ops) && ref.ops.length === 0 && !nodes.has(ref.id), "Invalid unresolved reference");
      nodes.set(ref.id, Object.assign({}, ref, {name: display(ref.name), ns: display(ref.ns)}));
    }
    const sites = new Map();
    let unresolved = 0;
    const refLabels = new Map();
    for (let i = 0; i < input.imports.length; i++) {
      const fact = input.imports[i], edge = snapshot.edges[i];
      const file = fact && files.get(fact.path), from = fact && nodes.get(fact.from), to = fact && nodes.get(fact.to);
      requireFact(file && file.profile_complete && from && from.file === fact.path && to &&
        resolutions.has(fact.resolution) && typeof fact.expression === "string" &&
        integer(fact.start_byte, 0, file.bytes) && integer(fact.end_byte, fact.start_byte + 1, file.bytes) &&
        integer(fact.line, 1, file.bytes + 1) && fact.source_sha256 === file.sha256 &&
        ["literal", "computed", "invalid_literal", "invalid_arguments"].includes(fact.argument_kind) &&
        (fact.literal === null || typeof fact.literal === "string" || (fact.resolution === "invalid_path" && rawBytes(fact.literal))), "Invalid import evidence");
      if (fact.argument_kind === "literal") {
        requireFact(fact.literal !== null && ["selected_file", "named_unresolved", "invalid_path", "outside_root", "not_in_snapshot"].includes(fact.resolution), "Literal-kind resolution mismatch");
        requireFact(["selected_file", "outside_root", "not_in_snapshot"].includes(fact.resolution)
          ? typeof fact.target_path === "string" : fact.target_path === null, "Literal target-path mismatch");
      } else {
        const expectedResolution = {computed: "computed_unresolved", invalid_literal: "invalid_literal", invalid_arguments: "invalid_arguments"}[fact.argument_kind];
        requireFact(fact.literal === null && fact.target_path === null && fact.resolution === expectedResolution, "Argument-kind resolution mismatch");
      }
      const site = fact.path + "\0" + fact.start_byte;
      requireFact(!sites.has(site), "Duplicate import site"); sites.set(site, i);
      if (fact.resolution === "selected_file") requireFact(to.file === fact.target_path && files.has(to.file), "Selected target mismatch");
      else {
        requireFact(to.resolution === fact.resolution && to.file === null &&
          fact.to === await referenceId(fact), "Unresolved target identity mismatch");
        const originalRef = snapshot.foreign.find(ref => ref.id === fact.to);
        const labels = refLabels.get(fact.to) || new Set();
        labels.add(JSON.stringify(fact.literal === null ? fact.expression : fact.literal));
        refLabels.set(fact.to, labels);
        requireFact(JSON.stringify(originalRef.ns) === JSON.stringify(fact.target_path === null ? (fact.literal === null ? fact.expression : fact.literal) : fact.target_path),
          "Unresolved target observation mismatch");
        unresolved++;
      }
      const ev = edge && edge.evidence && edge.evidence[0];
      requireFact(edge && edge.kind === "dependency" && edge.from === fact.from && edge.to === fact.to &&
        edge.label === fact.resolution && Array.isArray(edge.evidence) && edge.evidence.length === 1 && ev.file === fact.path &&
        ev.line === fact.line && ev.start_byte === fact.start_byte && ev.end_byte === fact.end_byte &&
        ev.source_sha256 === fact.source_sha256, "Relationship evidence mismatch");
    }
    for (const ref of snapshot.foreign)
      requireFact(refLabels.has(ref.id) && refLabels.get(ref.id).has(JSON.stringify(ref.name)), "Unresolved reference label has no captured site");
    requireFact(input.issues.every(i => i && typeof i.path === "string" && typeof i.reason === "string") &&
      (input.status === "partial" ? input.issues.length > 0 : input.issues.length === 0 && input.files.every(f => f.profile_complete)), "Partial status mismatch");
    const resolved = input.status === "complete" && input.files.every(f => f.profile_complete) && unresolved === 0;
    requireFact(typeof input.fully_resolved === "boolean" && input.fully_resolved === resolved &&
      snapshot.meta && snapshot.meta.status === input.status && snapshot.meta.fully_resolved === resolved &&
      snapshot.meta.source_manifest_sha256 === input.source_manifest_sha256 &&
      snapshot.meta.profile === input.profile && snapshot.meta.import_count === input.imports.length &&
      snapshot.meta.unresolved_import_count === unresolved, "Graph completeness mismatch");
    freeze(input);
    const foreign = snapshot.foreign.map(ref => nodes.get(ref.id));
    const foreignRefs = Object.fromEntries(foreign.map(ref => [ref.id, input.imports.filter(f => f.to === ref.id).length]));
    const document = Object.assign({}, snapshot, { foreign, meta: Object.assign({}, snapshot.meta, {
      class_count: files.size, package_count: groups.size, edge_count: input.imports.length,
      language: "zig", kind: "native_local", imported: true, foreign_refs: foreignRefs
    }) });
    function clazz(clsId) {
      const cls = nodes.get(clsId); if (!cls) return null;
      return Object.assign({}, cls, {
        incoming: snapshot.edges.map((e, i) => Object.assign({site: i}, e)).filter(e => e.to === clsId),
        outgoing: snapshot.edges.map((e, i) => Object.assign({site: i}, e)).filter(e => e.from === clsId)
      });
    }
    async function verify(site, bytes) {
      const fact = input.imports[site]; requireFact(fact, "No selected import site");
      const file = files.get(fact.path);
      requireFact(bytes instanceof Uint8Array && bytes.length <= LIMITS.sourceBytes &&
        bytes.length === file.bytes && await sha(bytes) === file.sha256, "Selected source bytes do not match snapshot");
      new TextDecoder("utf-8", {fatal: true}).decode(bytes);
      const span = bytes.slice(fact.start_byte, fact.end_byte), expected = encoder.encode(fact.expression);
      requireFact(span.length === expected.length && span.every((byte, i) => byte === expected[i]), "Captured expression bytes do not match source span");
      const decoded = new TextDecoder("utf-8", {fatal: true, ignoreBOM: true}).decode(span);
      requireFact(decoded === fact.expression, "Captured expression does not match source span");
      requireFact(bytes.slice(0, fact.start_byte).filter(b => b === 10).length + 1 === fact.line, "Captured line does not match source bytes");
      return {path: fact.path, line: fact.line, sha256: file.sha256, expression: decoded};
    }
    return Object.freeze({ input, document, nodes, groups, sites, clazz, verify });
  }
  const api = Object.freeze({limits: LIMITS, prepare});
  root.UmlishNative = api;
  if (typeof module !== "undefined") module.exports = api;
})(globalThis);
