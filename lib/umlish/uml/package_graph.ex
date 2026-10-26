defmodule Umlish.Uml.PackageGraph do
  @moduledoc """
  Derives the package-level view (Codex's recommended increment): a
  component graph over a stored snapshot document, with drill-down.

  * **nodes** — one per package: label, class count, member class ids
  * **edges** — class edges aggregated per package pair, keeping the
    contributing class pairs (bundled, like uml-viewer's collapsed
    component arrows) and their `file:line` evidence
  * **foreign** — per-package external references, so a small default
    view can still show what each component leans on

  Everything is a pure function of the stored document, so any snapshot
  — live internals or a past project scan — can be drilled into.
  """

  @max_pairs 50
  @max_evidence_per_pair 3

  @doc "Builds the package graph from a stored snapshot document (decoded JSON)."
  @spec build(map()) :: map()
  def build(document) do
    packages = document["packages"] || []
    edges = document["edges"] || []

    classes =
      Enum.flat_map(packages, fn pkg ->
        Enum.map(pkg["classes"] || [], &Map.put(&1, "package", pkg["id"]))
      end)

    class_package = Map.new(classes, &{&1["id"], &1["package"]})

    nodes =
      Enum.map(packages, fn pkg ->
        %{
          id: pkg["id"],
          label: pkg["label"],
          class_count: pkg["class_count"] || length(pkg["classes"] || []),
          classes: Enum.map(pkg["classes"] || [], & &1["id"])
        }
      end)

    package_edges =
      edges
      |> Enum.reduce(%{}, fn edge, acc ->
        from_pkg = class_package[edge["from"]]
        to_pkg = class_package[edge["to"]]

        if from_pkg && to_pkg && from_pkg != to_pkg do
          pair = %{
            from: edge["from"],
            to: edge["to"],
            kind: edge["kind"],
            evidence: take_evidence(edge["evidence"] || [])
          }

          Map.update(acc, {from_pkg, to_pkg}, [pair], &[pair | &1])
        else
          acc
        end
      end)
      |> Enum.map(fn {{from, to}, pairs} ->
        pairs = Enum.reverse(pairs)
        kinds = pairs |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

        %{
          from: from,
          to: to,
          kinds: kinds,
          pair_count: length(pairs),
          pairs: Enum.take(pairs, @max_pairs)
        }
      end)
      |> Enum.sort_by(&{-&1.pair_count, &1.from, &1.to})

    %{
      title: document["title"],
      snapshot_kind: get_in(document, ["meta", "kind"]),
      nodes: nodes,
      edges: package_edges,
      foreign: foreign_by_package(document)
    }
  end

  @doc "One package's drill-down: its classes and every edge crossing its boundary, with evidence."
  @spec package(map(), String.t()) :: map() | nil
  def package(document, package_id) do
    graph = build(document)

    case Enum.find(graph.nodes, &(&1.id == package_id)) do
      nil ->
        nil

      node ->
        outgoing =
          graph.edges
          |> Enum.filter(&(&1.from == package_id))
          |> Enum.map(&Map.take(&1, [:to, :kinds, :pair_count, :pairs]))

        incoming =
          graph.edges
          |> Enum.filter(&(&1.to == package_id))
          |> Enum.map(&Map.take(&1, [:from, :kinds, :pair_count, :pairs]))

        %{
          node: node,
          classes: classes_of(document, package_id),
          outgoing: outgoing,
          incoming: incoming,
          foreign: Map.get(graph.foreign, package_id, %{})
        }
    end
  end

  @doc "One class card: the class plus its incoming/outgoing dependencies with evidence."
  @spec clazz(map(), String.t()) :: map() | nil
  def clazz(document, class_id) do
    found =
      Enum.find_value(document["packages"] || [], fn pkg ->
        Enum.find(pkg["classes"] || [], &(&1["id"] == class_id))
      end)

    case found do
      nil ->
        nil

      class ->
        edges = document["edges"] || []

        incoming =
          edges
          |> Enum.filter(&(&1["to"] == class_id))
          |> Enum.map(fn edge ->
            %{
              from: edge["from"],
              kind: edge["kind"],
              evidence: take_evidence(edge["evidence"] || [])
            }
          end)

        outgoing =
          edges
          |> Enum.filter(&(&1["from"] == class_id))
          |> Enum.map(fn edge ->
            %{to: edge["to"], kind: edge["kind"], evidence: take_evidence(edge["evidence"] || [])}
          end)

        Map.merge(class, %{"incoming" => incoming, "outgoing" => outgoing})
    end
  end

  @doc "Renders the package graph as a Mermaid flowchart whose nodes call back into the UI."
  @spec mermaid(map()) :: String.t()
  def mermaid(graph) do
    node_lines =
      for node <- graph.nodes do
        safe = safe_id(node.id)
        ~s(  ) <> "#{safe}[\"" <> escape("#{node.label} (#{node.class_count})") <> "\"]"
      end

    foreign_lines =
      graph.foreign
      |> Enum.flat_map(fn {_package, refs} -> Map.keys(refs) end)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(40)
      |> Enum.map(fn segment ->
        safe = "f_" <> safe_id(segment)
        ~s(  ) <> "#{safe}{\"" <> escape(segment) <> " (external)\"}"
      end)

    package_ids = MapSet.new(graph.nodes, & &1.id)

    edge_lines =
      for edge <- graph.edges,
          edge.from in package_ids,
          edge.to in package_ids do
        kinds = Enum.join(edge.kinds, "+")
        "  #{safe_id(edge.from)} -->|\"#{edge.pair_count} × #{kinds}\"| #{safe_id(edge.to)}"
      end

    # Per-package foreign references, drawn to the shared foreign nodes:
    # a small default view still shows what each component leans on.
    foreign_edge_lines =
      graph.foreign
      |> Enum.flat_map(fn {package, refs} ->
        for segment <- Map.keys(refs), segment in foreign_targets(graph.foreign) do
          "  #{safe_id(package)} -.-> f_#{safe_id(segment)}"
        end
      end)
      |> Enum.uniq()
      |> Enum.take(200)

    clicks = for node <- graph.nodes, do: "  click #{safe_id(node.id)} umlPkgClick"

    [
      "flowchart TD",
      node_lines,
      foreign_lines,
      edge_lines,
      foreign_edge_lines,
      clicks
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp foreign_targets(foreign) do
    foreign |> Enum.flat_map(fn {_p, refs} -> Map.keys(refs) end) |> Enum.uniq() |> Enum.take(40)
  end

  defp classes_of(document, package_id) do
    Enum.find_value(document["packages"] || [], fn pkg ->
      if pkg["id"] == package_id, do: pkg["classes"] || []
    end) || []
  end

  # Foreign references per package: which external segment each
  # component's classes reference, and how often. Derived from the
  # document's per-class edges into foreign space... but the class
  # document drops foreign edges by design — the totals live in
  # meta.foreign_refs. Per-package detail therefore comes from
  # meta.foreign_by_package when the producer recorded it, falling back
  # to the global map keyed under "*" (shown on every package).
  defp foreign_by_package(document) do
    per_package = get_in(document, ["meta", "foreign_by_package"])

    if is_map(per_package) and per_package != %{} do
      per_package
      |> Enum.map(fn {package, refs} -> {package, refs || %{}} end)
      |> Map.new()
    else
      global = get_in(document, ["meta", "foreign_refs"]) || %{}
      if global == %{}, do: %{}, else: %{"*" => global}
    end
  end

  defp take_evidence(evidence) do
    evidence
    |> Enum.take(@max_evidence_per_pair)
    |> Enum.map(fn ev ->
      %{file: ev["file"] || ev[:file], line: ev["line"] || ev[:line]}
    end)
  end

  defp safe_id(id), do: id |> to_string() |> String.replace(~r/[^A-Za-z0-9_]/, "_")

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "'")
    |> String.replace("[", "(")
    |> String.replace("]", ")")
  end
end
