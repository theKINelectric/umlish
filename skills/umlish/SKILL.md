---
name: umlish
description: Display a project as UML via the UMLish web service — component graphs, class diagrams, and dependency evidence for a local codebase. Use when asked to visualize, map, or analyze the architecture/structure of a project directory, to see what depends on what, or to find a class's dependencies with file:line evidence.
---

# UMLish — display a project as UML

UMLish is a local web service (Phoenix + FlowExtra + SQLite) by 🛸🕳️ iStellar~iModal.
Point it at a local project directory and it returns a UML schema: packages
(components), classes with ops/fields, dependency edges each carrying
`file:line` evidence, and foreign-library references. Every run is snapshotted
to SQLite and can be drilled into later.

- Service base URL: `$UMLISH_URL` (default `http://127.0.0.1:4010` for a
  deployed instance; `mix phx.server` serves a dev instance on
  `http://127.0.0.1:4000`).
- CLI: `bin/umlish` (bash + curl, no other deps) — prefer it over raw curl.
- MCP: `mcp/umlish-mcp.mjs` (stdio, zero deps) when an MCP client is available.
- Both live in the umlish repo / deployment, alongside this skill.

## Quick start (CLI)

```bash
umlish() { /path/to/umlish/bin/umlish "$@"; }  # or add bin/ to PATH

ID=$(umlish scan /abs/path/to/project | jq -r '.meta.snapshot_id')
umlish scan /abs/path/to/project --scope all        # whole tree, not just src/
umlish internals                                      # live UML of the service itself
umlish graph "$ID"                                    # component graph (JSON)
umlish package "$ID" workbench                        # one component: classes + boundary edges
umlish class "$ID" src.workbench.flow                 # class card + evidence both directions
umlish mermaid "$ID"                                   # mermaid package-graph source
umlish latest --kind project                          # newest project snapshot id
```

Set `UMLISH_URL` if the service is elsewhere. `--mermaid` on scan/internals
returns a Mermaid `classDiagram` instead of JSON (feed straight to mermaid).

## Raw HTTP (when the CLI isn't installed)

| Request | Returns |
|---------|---------|
| `GET $UMLISH_URL/api/uml?path=DIR[&scope=all]` or `POST /api/uml {"path":DIR}` | class document (packages/classes/edges/foreign + `meta.snapshot_id`) |
| `GET /api/internals` | live BEAM introspection of the service itself |
| `GET /api/schemas/:id/graph` | component graph: nodes per package, edges per package pair with bundled class pairs + evidence, foreign refs per package |
| `GET /api/schemas/:id/graph/:package` | component detail |
| `GET /api/schemas/:id/classes/:class_id` | class card with incoming/outgoing deps and `file:line` evidence |
| `GET /api/schemas[/:id]` | snapshot history / replay |
| append `?as=mermaid` | Mermaid rendering of any document endpoint |

Errors are JSON: `{"error": {"status": 422, "message": "…"}}`; 4xx = caller
mistake (bad path, no scanner), 503/504 = the internal FlowExtra pipeline
refused/timed out (retryable).

## Reading the document

- `ns` — the language's own identifier (Elixir module name, source-file path)
- `id` — canonical dotted id (always the full namespace; same-basename files
  in different trees never collide). Package = the class's `package` field.
- edge kinds: `dependency` (default), `implements`, `inheritance`,
  `association`, `aggregation`, `composition`
- `evidence` — array of `{file, line}` sites that produced the edge
- `foreign` — external segments (`Phoenix.LiveView` → `Phoenix`, `std`),
  with reference counts in `meta.foreign_refs` and per-package in
  `meta.foreign_by_package`
- Languages detected by marker files: `mix.exs` → Elixir (AST scan; alias
  resolution, `use`/`import`/calls/`%Mod{}` refs, `@behaviour`/`defimpl`),
  `build.zig` → Zig (one class per file, `pub fn` ops, `@import` edges,
  `addModule` roots from build.zig)

## Typical agent flows

Find what a project's components are and how they couple:

```bash
ID=$(umlish scan "$PROJECT" | jq -r '.meta.snapshot_id')
umlish graph "$ID" | jq '.edges[] | {from, to, pair_count, kinds}'
```

Find the blast radius of one class (and prove each edge from source):

```bash
umlish class "$ID" "$CLASS" | jq '{outgoing, incoming}'
```

See what a component leans on externally:

```bash
umlish graph "$ID" | jq --arg p workbench '.foreign[$p]'
```

Regenerate after edits and compare snapshots (`meta.class_count`,
`edge_count`, or full-document diffs via `/api/schemas/:id`).

## Deploying / running the service

```bash
mix deps.get && mix ecto.create && mix ecto.migrate && mix phx.server
```
