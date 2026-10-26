defmodule Umlish.Uml.Mermaid do
  @moduledoc """
  Renders a `Umlish.Uml.Schema` as a Mermaid `classDiagram`.

  Packages become `namespace` blocks, classes become nodes with
  `+public`/`-private` member lines, and edge kinds map onto Mermaid
  arrows. Foreign libraries get their own namespace with an `(external)`
  marker (uml-viewer draws them as ovals); edges *to* foreign classes
  are not drawn — a project leaning on `std` or `Kernel` would otherwise
  be nothing but arrows — the JSON keeps them, and the UI shows
  reference counts instead.
  """

  alias Umlish.Uml.Schema

  @edge_arrows %{
    dependency: "-->",
    implements: "..|>",
    inheritance: "--|>",
    association: "--",
    aggregation: "o--",
    composition: "*--"
  }

  @stereotype_annotations %{
    interface: "interface",
    abstract: "abstract",
    enumeration: "enumeration"
  }

  @spec render(Schema.t()) :: String.t()
  def render(%Schema{} = schema) do
    ids = build_ids(schema)

    # Mermaid namespaces accept class declarations but not member lines —
    # members are appended after all namespace blocks.
    {namespace_lines, member_lines} =
      Enum.reduce(schema.packages, {[], []}, fn package, {ns_acc, member_acc} ->
        {decls, members} =
          Enum.reduce(package.classes, {[], member_acc}, fn class, {decls, members} ->
            node = ids[class.id].node

            {
              decls ++ [~s(    ) <> "class #{node}[\"" <> escape(class.name) <> "\"]"],
              members ++ member_lines(node, class)
            }
          end)

        {ns_acc ++ ["  namespace #{safe_name(package.id)} {" | decls] ++ ["  }"], members}
      end)

    foreign_lines =
      if schema.foreign == [] do
        []
      else
        decls =
          Enum.map(schema.foreign, fn class ->
            node = ids[class.id].node
            ~s(    ) <> "class #{node}[\"" <> escape(class.name) <> " (external)\"]"
          end)

        ["  namespace Foreign {" | decls] ++ ["  }"]
      end

    foreign_members =
      Enum.flat_map(schema.foreign, fn class ->
        member_lines(ids[class.id].node, class)
      end)

    edges = Enum.map(schema.edges, &edge_line(&1, ids))

    ["classDiagram", "  direction #{String.upcase(to_string(schema.direction))}"]
    |> Enum.concat(namespace_lines)
    |> Enum.concat(foreign_lines)
    |> Enum.concat(member_lines)
    |> Enum.concat(foreign_members)
    |> Enum.concat(edges)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp member_lines(node, %Schema.Class{} = class) do
    stereotype = @stereotype_annotations[class.stereotype]

    field_lines =
      for field <- class.fields do
        type = if field.type, do: " " <> member_token(field.type), else: ""
        ~s(    ) <> "#{node} : #{visibility_mark(:public)}#{member_token(field.name)}#{type}"
      end

    op_lines =
      for op <- class.ops do
        args = Enum.map_join(op.args, ", ", &member_token/1)
        ~s(    ) <> "#{node} : #{visibility_mark(op.visibility)}#{member_token(op.name)}(#{args})"
      end

    stereotype_line =
      if stereotype, do: ~s(    ) <> "#{node} : <<#{stereotype}>>", else: nil

    [stereotype_line | field_lines ++ op_lines]
  end

  defp visibility_mark(:public), do: "+"
  defp visibility_mark(:private), do: "-"

  defp edge_line(%Schema.Edge{} = edge, ids) do
    with %{} = from <- ids[edge.from],
         %{} = to <- ids[edge.to] do
      arrow = Map.get(@edge_arrows, edge.kind, @edge_arrows.dependency)
      label = if edge.label, do: " : " <> escape(edge.label), else: ""
      ~s(  ) <> "#{from.node} #{arrow} #{to.node}#{label}"
    else
      _ -> nil
    end
  end

  # Stable node ids: mermaid ids must be alphanumeric/underscore, so class
  # ids like "src.workbench.flow" map onto c0, c1, … deterministically.
  defp build_ids(%Schema{} = schema) do
    all = Enum.flat_map(schema.packages, & &1.classes) ++ schema.foreign

    all
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {id, index} -> {id, %{node: "c#{index}"}} end)
  end

  defp safe_name(id) do
    id |> to_string() |> String.replace(~r/[^A-Za-z0-9_]/, "_")
  end

  # Member lines carry their own micro-grammar: `:` separates the node
  # from the member, so ids like `:query` or `overdue?` must be reduced
  # to plain tokens.
  defp member_token(text) do
    text
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_]/, "")
    |> case do
      "" -> "_"
      token -> token
    end
  end

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "'")
    |> String.replace("[", "(")
    |> String.replace("]", ")")
  end

  defp escape(other), do: escape(to_string(other))
end
