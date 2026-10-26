defmodule Umlish.Uml.Scanner do
  @moduledoc """
  The language seam (uml-viewer calls this a `LanguageGraph`).

  Every producer — source scanners and the live introspector — returns
  the same fact shape, so the pipeline's resolve/assemble stages stay
  language-neutral:

      %{
        title: String.t(),
        language: :elixir | :zig | :beam,
        prefixes: [String.t()],        # namespace prefixes to strip
        classes: [class_fact],
        edges: [edge_fact],            # ns-based, not yet resolved
        errors: [String.t()]
      }

      class_fact = %{
        ns: String.t(),                # language's own module identifier
        stereotype: Schema.stereotype,
        lang: atom,
        file: String.t() | nil,
        fields: [%{name: name, type: type | nil}],
        ops: [%{name: name, args: [String.t()], arity: arity, visibility: :public | :private}]
      }

      edge_fact = %{from: ns, to: ns_or_ref, kind: Schema.edge_kind}

  An edge whose `to` is not among the collected classes is treated as a
  foreign reference and collapsed to its leading namespace segment.
  """

  alias Umlish.Uml.Schema

  @callback scan(Path.t() | nil, map()) :: {:ok, map()} | {:error, term()}

  @doc "Collapses a namespace reference to its foreign (external library) segment."
  @spec foreign_segment(String.t()) :: String.t()
  def foreign_segment(ref) when is_binary(ref) do
    ref
    |> String.trim_leading(":")
    |> String.split(".")
    |> List.first()
    |> case do
      nil -> ref
      seg -> seg
    end
  end

  @doc "Builds a `Schema.Class` struct from a scanner class fact (id is filled in later)."
  @spec to_class(map()) :: Schema.Class.t()
  def to_class(fact) do
    %Schema.Class{
      id: fact.ns,
      name: fact[:name] || fact.ns |> String.split(".") |> List.last(),
      ns: fact.ns,
      stereotype: fact.stereotype,
      lang: fact.lang,
      file: fact.file,
      fields: Enum.map(fact.fields || [], &to_field/1),
      ops: Enum.map(fact.ops || [], &to_op/1)
    }
  end

  defp to_field(%{name: name} = f),
    do: %Schema.Field{name: to_string(name), type: f[:type] && to_string(f[:type])}

  defp to_op(%{name: name} = o) do
    %Schema.Op{
      name: to_string(name),
      args: Enum.map(o[:args] || [], &to_string/1),
      arity: o[:arity] || length(o[:args] || []),
      visibility: o[:visibility] || :public,
      returns: o[:returns] && to_string(o[:returns])
    }
  end
end
