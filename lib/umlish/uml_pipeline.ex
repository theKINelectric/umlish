defmodule Umlish.UmlPipeline do
  @moduledoc """
  The UML generation flow — a FlowExtra (Flow-Based Programming)
  railway. One HTTP request is one Information Packet travelling
  through one GenStage process per transformation:

      validate ──▶ discover ──▶ parse ──▶ resolve ──▶ assemble ──▶ persist

  * `validate`    — checks the request (kind, path) and rejects early
  * `discover`    — picks the producer: the live introspector for
                    `/internals`, or the language scanner a directory
                    smells of (mix.exs → Elixir, build.zig → Zig)
  * `parse`       — runs it over the sources (files parse in parallel)
  * `resolve`     — turns native names into canonical class ids,
                    keeps project-to-project edges, and collapses
                    everything else into foreign classes
  * `assemble`    — groups classes into packages and stamps meta
  * `persist`     — records the document in SQLite

  Any stage that raises bypasses to `capture`, which routes the error
  into the packet instead of killing the request — the caller always
  gets an answer, never a timeout. Stages are replicated (`count:`)
  so concurrent requests flow through in parallel, FBP style.
  """

  use FlowExtra.Pipeline
  alias Umlish.Uml.{ElixirScanner, Introspector, Json, Schema, ZigScanner}

  # Compiler/debug modules that would only add noise to the foreign list.
  @foreign_noise [
    "Kernel",
    "Kernel.SpecialForms",
    "Elixir",
    "Mix",
    "ex_unit",
    "erlang",
    "elixir_erl_pass",
    "elixir_erl_try",
    "elixir_compiler",
    "beam_lib",
    "code",
    "binary"
  ]

  @type t :: %__MODULE__{}

  # FlowExtra rebuilds this struct at every stage boundary, so anything
  # that must survive to a later stage is declared here.
  defstruct [
    :job_id,
    :kind,
    :path,
    :scope,
    :scanner,
    :scan,
    :resolved,
    :schema,
    :snapshot_id,
    errors: [],
    notes: [],
    started_at: nil,
    finished_at: nil
  ]

  pipe(:validate, count: 2)
  pipe(:discover, count: 2)
  pipe(:parse, count: 3)
  pipe(:resolve, count: 2)
  pipe(:assemble, count: 2)
  pipe(:persist, count: 1)

  error_pipe(:capture, count: 1)

  # -- stages --------------------------------------------------------------

  def validate(data, _opts) do
    case data do
      %{kind: :internals} = data ->
        %{data | scope: normalize_scope(data.scope)}

      %{kind: :project, path: path} = data when is_binary(path) ->
        expanded = Path.expand(path)

        unless File.dir?(expanded) do
          raise ArgumentError, "not a readable directory: #{expanded}"
        end

        %{data | path: expanded, scope: normalize_scope(data.scope)}

      _ ->
        raise ArgumentError, "expected kind :internals or :project with a path"
    end
  end

  def discover(data, _opts) do
    scanner =
      case data.kind do
        :internals ->
          Introspector

        :project ->
          cond do
            File.exists?(Path.join(data.path, "mix.exs")) -> ElixirScanner
            File.exists?(Path.join(data.path, "build.zig")) -> ZigScanner
            true -> raise ArgumentError, "no scanner for #{data.path}: need mix.exs or build.zig"
          end
      end

    %{data | scanner: scanner}
  end

  def parse(data, _opts) do
    case data.scanner.scan(data.path, %{scope: data.scope}) do
      {:ok, scan} ->
        %{data | scan: scan}

      {:error, reason} ->
        raise ArgumentError, "scan failed: #{inspect(reason)}"
    end
  end

  def resolve(data, _opts) do
    scan = data.scan

    classes =
      Enum.map(scan.classes, fn
        %Schema.Class{} = class -> %Schema.Class{class | id: canonical_id(class.ns)}
      end)

    known = MapSet.new(classes, & &1.id)
    # Which package each class belongs to — needed to attribute foreign
    # references to the component that leans on them.
    package_of = Map.new(classes, &{&1.id, Schema.classify(&1.id, scan.prefixes) |> elem(0)})

    {edges, foreign_counts, foreign_by_package} =
      Enum.reduce(scan.edges, {[], %{}, %{}}, fn
        %Schema.Edge{} = edge, {edges, foreign, per_package} ->
          from = canonical_id(edge.from)
          to = canonical_id(edge.to)

          cond do
            MapSet.member?(known, from) and MapSet.member?(known, to) ->
              {[%Schema.Edge{edge | from: from, to: to} | edges], foreign, per_package}

            MapSet.member?(known, from) ->
              segment = Umlish.Uml.Scanner.foreign_segment(to)

              if segment in @foreign_noise do
                {edges, foreign, per_package}
              else
                # Merge case twins (`File`/`:file`) so the oval list stays clean.
                foreign = Map.update(foreign, segment, 1, &(&1 + 1))
                package = Map.get(package_of, from)
                key = String.capitalize(segment)

                per_package =
                  if package do
                    Map.update(per_package, package, %{key => 1}, fn refs ->
                      Map.update(refs, key, 1, &(&1 + 1))
                    end)
                  else
                    per_package
                  end

                {edges, foreign, per_package}
              end

            true ->
              {edges, foreign, per_package}
          end
      end)

    foreign_counts =
      foreign_counts
      |> Enum.map(fn {segment, count} -> {String.capitalize(segment), count} end)
      |> Enum.reduce(%{}, fn {segment, count}, acc ->
        Map.update(acc, segment, count, &(&1 + count))
      end)

    foreign =
      foreign_counts
      |> Enum.sort_by(fn {segment, count} -> {-count, segment} end)
      |> Enum.map(fn {segment, _count} ->
        %Schema.Class{
          id: segment,
          name: Schema.prettify(segment),
          ns: segment,
          package_id: nil,
          stereotype: nil,
          lang: nil
        }
      end)

    %{
      data
      | scan: %{scan | classes: classes},
        resolved: %{
          edges: Schema.dedup_edges(edges),
          foreign: foreign,
          foreign_counts: foreign_counts,
          foreign_by_package: foreign_by_package
        }
    }
  end

  def assemble(data, _opts) do
    scan = data.scan
    resolved = data.resolved
    finished_at = System.monotonic_time(:millisecond)
    duration_ms = finished_at - (data.started_at || finished_at)

    packages = Schema.group_packages(scan.classes, scan.prefixes)

    schema = %Schema{
      title: scan.title,
      direction: :tb,
      packages: packages,
      edges: resolved.edges,
      foreign: resolved.foreign,
      meta: %{
        kind: data.kind,
        project_path: data.path,
        scope: data.scope || :default,
        language: scan.language,
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        duration_ms: duration_ms,
        class_count: length(scan.classes),
        package_count: length(packages),
        edge_count: length(resolved.edges),
        errors: scan.errors,
        foreign_refs: resolved.foreign_counts,
        foreign_by_package: resolved.foreign_by_package
      }
    }

    %{data | schema: schema, finished_at: finished_at}
  end

  def persist(data, opts) do
    if Map.get(opts, :persist, true) do
      meta = data.schema.meta

      case Umlish.Snapshots.record(%{
             kind: to_string(data.kind),
             title: data.schema.title,
             project_path: data.path,
             language: to_string(meta.language),
             class_count: meta.class_count,
             package_count: meta.package_count,
             edge_count: meta.edge_count,
             duration_ms: meta.duration_ms,
             document: Json.to_map(data.schema)
           }) do
        {:ok, snapshot} ->
          %{data | snapshot_id: snapshot.id}

        {:error, reason} ->
          %{data | notes: ["snapshot not stored: #{inspect(reason)}" | data.notes]}
      end
    else
      data
    end
  end

  # Errors land here instead of the caller timing out: the packet comes
  # back carrying the message, and the controller maps it to 4xx/5xx.
  def capture(error, data, _opts) do
    message =
      if is_exception(error) do
        Exception.message(error)
      else
        inspect(error)
      end

    %{data | errors: [message | data.errors], finished_at: System.monotonic_time(:millisecond)}
  end

  # -- helpers ---------------------------------------------------------------

  # :all is the only override today; scanners fall back to their own
  # default (:src_roots for Zig) when scope is nil.
  defp normalize_scope("all"), do: :all
  defp normalize_scope(all) when all in [:all, :src_roots], do: all
  defp normalize_scope(_), do: nil

  # Native ns → canonical dotted id: Zig paths carry slashes and a
  # .zig extension; Elixir module names are already dotted.
  defp canonical_id(ns) when is_binary(ns) do
    ns |> String.replace("/", ".") |> String.trim_trailing(".zig")
  end
end
