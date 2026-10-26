#!/usr/bin/env node
// umlish-mcp — Model Context Protocol (stdio) server for the UMLish service.
//
// Zero dependencies. Speaks newline-delimited JSON-RPC 2.0 on stdio and
// wraps the UMLish HTTP API (see bin/umlish for the curl equivalent).
//
// Register with an MCP client:
//   { "mcpServers": { "umlish": {
//       "command": "node",
//       "args": ["/abs/path/mcp/umlish-mcp.mjs"],
//       "env": { "UMLISH_URL": "http://127.0.0.1:4010" } } } }
//
// Tools:
//   umlish_scan        { path, scope? }        — UML of a local project directory
//   umlish_internals   {}                      — live UML of the UMLish service itself
//   umlish_graph       { snapshot_id? }        — package/component graph
//   umlish_package     { snapshot_id?, package } — one component's drill-down
//   umlish_class       { snapshot_id?, class_id } — class card + file:line evidence
//   umlish_latest      { kind? }               — newest snapshot id
//
// Every tool returns the JSON document; scans include meta.snapshot_id,
// which the drill-down tools accept (defaulting to the latest snapshot).

import process from "node:process";

const BASE = (process.env.UMLISH_URL || "http://127.0.0.1:4010").replace(/\/$/, "");
const TIMEOUT_MS = Number(process.env.UMLISH_TIMEOUT || 120000);

async function api(path) {
  const res = await fetch(BASE + path, { signal: AbortSignal.timeout(TIMEOUT_MS) });
  const text = await res.text();
  if (!res.ok) {
    let message = text;
    try { message = JSON.parse(text)?.error?.message || text; } catch {}
    throw new Error(`HTTP ${res.status} from ${path}: ${message}`);
  }
  return text;
}

async function latestSnapshotId() {
  const body = JSON.parse(await api("/api/schemas"));
  return body?.data?.[0]?.id ?? null;
}

const TOOLS = [
  {
    name: "umlish_scan",
    description:
      "Scan a local project directory and return its UML schema as JSON: packages, classes, " +
      "ops/fields, dependency edges with file:line evidence, foreign libraries. Detects the " +
      "language (mix.exs -> Elixir, build.zig -> Zig). meta.snapshot_id feeds the drill-down tools.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "absolute path to the project directory" },
        scope: {
          type: "string",
          enum: ["all"],
          description: "omit for the primary src/lib roots; 'all' walks the whole tree",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "umlish_internals",
    description:
      "Live UML of the UMLish service itself, from BEAM introspection: modules actually loaded, " +
      "exports, struct fields, behaviours, compiled remote calls as edges.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "umlish_graph",
    description:
      "The package/component graph of a snapshot: one node per package, class edges aggregated " +
      "per package pair (bundled pairs + evidence), foreign references per package. Defaults to " +
      "the latest snapshot.",
    inputSchema: {
      type: "object",
      properties: { snapshot_id: { type: "integer", description: "from meta.snapshot_id; default latest" } },
    },
  },
  {
    name: "umlish_package",
    description:
      "Drill into one package of a snapshot: its classes plus every incoming/outgoing dependency " +
      "across the boundary, with contributing class pairs and file:line evidence.",
    inputSchema: {
      type: "object",
      properties: {
        snapshot_id: { type: "integer", description: "default latest" },
        package: { type: "string", description: "package id, e.g. 'workbench' or 'Web'" },
      },
      required: ["package"],
    },
  },
  {
    name: "umlish_class",
    description:
      "Class card: the class (ops, fields, file, stereotype) plus its incoming and outgoing " +
      "dependencies, each with file:line evidence for where the reference occurs.",
    inputSchema: {
      type: "object",
      properties: {
        snapshot_id: { type: "integer", description: "default latest" },
        class_id: { type: "string", description: "dotted class id, e.g. 'src.workbench.flow'" },
      },
      required: ["class_id"],
    },
  },
  {
    name: "umlish_latest",
    description: "Newest snapshot id (optionally filtered by kind), for follow-up drill-downs.",
    inputSchema: {
      type: "object",
      properties: { kind: { type: "string", enum: ["internals", "project"] } },
    },
  },
];

async function callTool(name, args) {
  args = args || {};
  switch (name) {
    case "umlish_scan": {
      let path = `/api/uml?path=${encodeURIComponent(args.path)}`;
      if (args.scope) path += `&scope=${encodeURIComponent(args.scope)}`;
      return api(path);
    }
    case "umlish_internals":
      return api("/api/internals");
    case "umlish_graph": {
      const id = args.snapshot_id || (await latestSnapshotId());
      if (!id) throw new Error("no snapshots stored yet — run a scan first");
      return api(`/api/schemas/${id}/graph`);
    }
    case "umlish_package": {
      const id = args.snapshot_id || (await latestSnapshotId());
      if (!id) throw new Error("no snapshots stored yet — run a scan first");
      return api(`/api/schemas/${id}/graph/${encodeURIComponent(args.package)}`);
    }
    case "umlish_class": {
      const id = args.snapshot_id || (await latestSnapshotId());
      if (!id) throw new Error("no snapshots stored yet — run a scan first");
      return api(`/api/schemas/${id}/classes/${encodeURIComponent(args.class_id)}`);
    }
    case "umlish_latest": {
      const id = await latestSnapshotId();
      return JSON.stringify({ snapshot_id: id });
    }
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

let pending = 0;
let stdinEnded = false;

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + "\n");
}

function maybeExit() {
  if (stdinEnded && pending === 0) process.exit(0);
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let nl;
  while ((nl = buffer.indexOf("\n")) !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (!line) continue;
    let req;
    try {
      req = JSON.parse(line);
    } catch {
      continue; // not JSON-RPC; ignore
    }
    if (req.id !== undefined) pending++;
    handle(req)
      .catch((err) => {
        if (req.id !== undefined) {
          send({ jsonrpc: "2.0", id: req.id, error: { code: -32603, message: String(err?.message || err) } });
        }
      })
      .finally(() => {
        if (req.id !== undefined) pending--;
        maybeExit();
      });
  }
});
process.stdin.on("end", () => {
  stdinEnded = true;
  maybeExit(); // drain in-flight requests before exiting
});

async function handle(req) {
  const method = req.method;

  if (method === "initialize") {
    send({
      jsonrpc: "2.0",
      id: req.id,
      result: {
        protocolVersion: req.params?.protocolVersion || "2024-11-05",
        capabilities: { tools: {} },
        serverInfo: { name: "umlish-mcp", version: "1.0.0" },
      },
    });
    return;
  }
  if (method === "notifications/initialized" || method === "notifications/cancelled") return;
  if (method === "ping") {
    send({ jsonrpc: "2.0", id: req.id, result: {} });
    return;
  }
  if (method === "tools/list") {
    send({ jsonrpc: "2.0", id: req.id, result: { tools: TOOLS } });
    return;
  }
  if (method === "tools/call") {
    const name = req.params?.name;
    const args = req.params?.arguments;
    try {
      const text = await callTool(name, args);
      send({
        jsonrpc: "2.0",
        id: req.id,
        result: { content: [{ type: "text", text }], isError: false },
      });
    } catch (err) {
      send({
        jsonrpc: "2.0",
        id: req.id,
        result: { content: [{ type: "text", text: String(err?.message || err) }], isError: true },
      });
    }
    return;
  }

  if (req.id !== undefined) {
    send({ jsonrpc: "2.0", id: req.id, error: { code: -32601, message: `method not found: ${method}` } });
  }
}
