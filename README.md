# UMLish — display a project as UML

**A 🛸🕳️ [iStellar~iModal](https://stellarmodal.online) creation.**

A standalone web service, modeled on [unclebob/uml-viewer](https://github.com/unclebob/uml-viewer):
point it at a local project (or at itself) and it answers with a UML schema —
packages, classes, ops, fields, and dependency edges — as JSON or as a
Mermaid class diagram. Service scan runs are snapshotted to SQLite; local native graph imports stay in browser memory.

Built with **Phoenix** (Bandit) + **FlowExtra** (Flow-Based Programming on
GenStage, `../flow_extra`) + **SQLite** (`ecto_sqlite3`).

## Built for agents

UMLish is most often driven by agents working on applications. Three doors,
all speaking the same HTTP API:

* **CLI** — `bin/umlish scan /path/to/project`, `umlish graph`, `umlish package`,
  `umlish class`, `umlish internals`, `umlish mermaid`, `umlish latest`.
  Bash + curl, zero other dependencies. `UMLISH_URL` selects the instance.
* **MCP** — `mcp/umlish-mcp.mjs` (stdio, zero deps) exposes `umlish_scan`,
  `umlish_internals`, `umlish_graph`, `umlish_package`, `umlish_class`,
  `umlish_latest` to any MCP client.
* **Skill** — `skills/umlish/SKILL.md` is an installable agent skill
  describing everything above; drop it into your agent's skills directory.

The service's front page (`/`) carries the same instructions, always in
sync with the deployed instance.

## Run

```bash
mix deps.get
mix ecto.create && mix ecto.migrate
mix phx.server          # http://127.0.0.1:4000
```


## The web UI

`http://127.0.0.1:4000/` — one page:

* **⊙ View this service's internals** — the live introspective diagram
* **▶ Analyze project** — paste a local directory, get its UML
* tabs: **Package graph** (the default — components, bundled arrows,
  click a node to drill into classes and dependencies, dotted arrows to
  foreign libraries), Class diagram (Mermaid, CDN — degrades gracefully
  offline), Packages, Edges, raw JSON
* class cards with incoming/outgoing dependencies and `file:line` evidence
* the URL hash carries the whole view (`#s=<snapshot>&p=<package>&c=<class>`)
  — reload or share it and the exact drill-down is restored
* snapshot history from SQLite, click to replay any past run

## Local HoneyBadger source graphs

Use **Open HoneyBadger graph** to select native
`honeybadger.architecture.v1 / zig-0.16-imports.v1` JSON from
`hb-analyze architecture /absolute/source/root`. The local adapter checks
identities and matching graph evidence, then renders a local SVG without a
service scan or Mermaid CDN. Every admitted import site remains inspectable.
Partial results and unresolved targets are visible; unresolved does not mean
external deployment.

Choose a relationship or an **Edges** evidence button to inspect its captured
expression, path, line, exclusive byte span and SHA256. Select the matching
source file to verify whole-file digest and exact span/line. This checks
captured source bytes, not authenticated provenance or Zig semantics.

Local admission is 2 MiB JSON, 512 files and 2,048 import sites; optional source
verification admits 1 MiB/file. SVG shows at most 60 nodes/200 relationships
with visible counts, while Edges retains all admitted sites. Refused input
retains the prior accepted document. Local imports are not persisted to SQLite
or restored by a shared URL: reopen the JSON after reload.

A standalone export of this same browser UI and its actual Chrome/CDP
qualification live in HoneyBadger's `apps/workshop_analysis/export_viewer.py`
and `viewer_qualification.mjs`. The source-identified HTML opens locally
without Phoenix. Qualification covers that browser path; production service
execution/deployment, an editable design canvas and Cucumber runner remain
separate work. See the sibling HoneyBadger
`_building_docs/hb003/workshop-viewer/REHEARSAL.md` and `QUALIFICATION.md`.

## API

| Endpoint | Meaning |
|----------|---------|
| `GET /api/internals` | UML schema of **this running service** — live BEAM introspection: every module actually loaded, exports, struct fields, behaviours, and the remote calls compiled into the beams |
| `GET /api/uml?path=DIR` · `POST /api/uml {"path": DIR}` | UML schema of a local project directory. Detects the language: `mix.exs` → Elixir, `build.zig` → Zig. `&scope=all` walks the whole tree (default: the primary `src`/`lib` roots — repositories like honey_badger carry thousands of exploratory files outside them) |
| `GET /api/schemas` | SQLite snapshot history |
| `GET /api/schemas/:id` | replay one snapshot |
| `GET /api/schemas/:id/graph` | **drill-down**: the package graph — nodes per component, edges aggregated per package pair with the contributing class pairs and `file:line` evidence, foreign refs per package. `?as=mermaid` renders a flowchart whose nodes call back into the UI |
| `GET /api/schemas/:id/graph/:package` | one component: its classes, incoming/outgoing dependencies with evidence |
| `GET /api/schemas/:id/classes/:class_id` | one class card: ops, fields, both dependency directions with `file:line` evidence |

Every document endpoint also answers `?as=mermaid` with a Mermaid
`classDiagram` rendering of the same schema (stored snapshots replay with
their edges intact).

Errors: caller mistakes are 4xx (`400` missing/malformed path, `422` bad
directory or unknown project kind). Flow failures are surfaced, not
swallowed: admission refusals answer `503` + `Retry-After`, an expired
flow budget answers `504`, deeper failures `500` — FlowExtra's
definite-refusal vs `:unacknowledged` distinction is preserved in the
message. `meta.scope` records the scan scope actually used.

Example:

```bash
curl -s 'http://127.0.0.1:4000/api/uml?path=/abs/path/to/project' | jq '.meta'
curl -s 'http://127.0.0.1:4000/api/internals?as=mermaid'
```

Every edge in the document also carries `evidence` — the source sites
that produced it (`{"file": "src/root.zig", "line": 2}` for the `@import`,
the alias/use/call line for Elixir, the compiled call line for
internals) — so drill-down views can show *why* an edge exists.

### The document

Faithful JSON mirror of uml-viewer's EDN IR:

```json
{
  "title": "honey_badger (Zig sources)",
  "direction": "tb",
  "packages": [
    {"id": "workbench", "label": "Workbench", "classes": [
      {"id": "src.workbench.flow", "ns": "src/workbench/flow.zig",
       "name": "Flow", "stereotype": "class", "lang": "zig",
       "file": "src/workbench/flow.zig",
       "fields": [{"name": "Result", "type": "struct"}],
       "ops": [{"name": "transform", "args": ["input"], "arity": 1,
                "visibility": "public"}]}
    ]}
  ],
  "edges": [{"from": "src.root", "to": "src.engine.tune", "kind": "dependency"}],
  "foreign": [{"id": "Std", "name": "Std"}],
  "meta": {"kind": "project", "language": "zig", "class_count": 49, "...": "..."}
}
```

Service document identity rules (native HoneyBadger envelopes use their versioned hashed IDs):

* `ns` is the language's own identifier (module name, file path)
* `id` is the ns in canonical dotted form — always the full namespace, so
  same-basename files in different trees never collide
* packages (components) come from the segments after the project prefix;
  the class id's first segment names the package (`workbench` above)
* edge kinds: `dependency` · `implements` · `inheritance` · `association` ·
  `aggregation` · `composition`
* references that leave the project collapse to `foreign` segments
  (`Phoenix.LiveView` → `Phoenix`, `@import("std")` → `std`)

## How it works — the flow

One HTTP request is one Information Packet through a **FlowExtra**
pipeline; each stage is its own GenStage process pool:

```
validate ──▶ discover ──▶ parse ──▶ resolve ──▶ assemble ──▶ persist
 (2)          (2)         (3)       (2)         (2)          (1)
```

* **validate** — checks kind/path, rejects early
* **discover** — picks the producer: the live introspector
  (`/api/internals`) or a language scanner (`mix.exs` → Elixir AST,
  `build.zig` → Zig text scan, incl. `addModule` roots from build.zig)
* **parse** — runs it (files parse in parallel via tasks)
* **resolve** — native names → canonical ids, project-to-project edges
  kept, everything else collapses into foreign classes
* **assemble** — groups classes into packages, stamps meta
* **persist** — writes the document to SQLite (never kills a good
  diagram on failure)

A stage that raises bypasses to the `capture` error pipe, which routes
the message into the packet — callers always get an answer. The pipeline
is started once under the application supervisor and shared by every
request; FlowExtra's admission control bounds concurrent work.

### Producers

| Module | Source of truth |
|--------|-----------------|
| `Umlish.Uml.Introspector` | the running BEAM: `:code.all_loaded/0`, beams preloaded from ebin, exports + abstract-code arg names, `__struct__/0` fields, `__info__(:behaviours)`, remote calls from abstract code |
| `Umlish.Uml.ElixirScanner` | quoted AST of `lib/**/*.ex` (+ umbrellas): defmodule nesting, def/defp heads, defstruct fields, `@callback`/`defprotocol` → interface, `@behaviour`/`defimpl` → implements, `use`/`import`/`alias`/remote calls → dependencies (alias resolution incl. `Foo.{Bar,Baz}` and `as:`) |
| `Umlish.Uml.ZigScanner` | text scan: one class per `.zig` file, `pub fn` ops, `pub const X = struct/enum/…` fields, `@import("rel.zig")` and build.zig module roots → dependencies, `std`/`builtin` → foreign |

## Layout

```
lib/umlish/uml/        schema.ex (IR) · json.ex · mermaid.ex · scanner.ex
                           elixir_scanner.ex · zig_scanner.ex · introspector.ex
lib/umlish/uml_pipeline.ex   the FlowExtra flow (stages + capture)
lib/umlish/uml_runner.ex     request-facing door, shared supervised pipeline
lib/umlish/snapshots.ex      SQLite snapshot store (Ecto)
lib/umlish_web/        Phoenix: router, Api controllers, viewer page
test/                      unit + fixture-project + API tests (31)
```

## Test

```bash
mix test
```

Fixtures under `test/fixtures/` (a tiny Elixir project and a tiny Zig
project) pin the scanners' semantics; the API tests run the real flow
end-to-end against the sandboxed SQLite DB.

## Differences from unclebob/uml-viewer

The original is a Quil desktop app driven by EDN files and a companion
agent; ours is a stateless HTTP service — no agent, no proposals yet.
Shared: the IR shape (packages/classes/edges/foreign, edge kinds,
«interface» stereotypes, foreign ovals), the "one class per module/file"
rule, and the idea that the tree *is* the namespaces — nothing invented.
