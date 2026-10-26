defmodule Umlish.Uml.Json do
  @moduledoc """
  Encodes a `Umlish.Uml.Schema` into the JSON document served by the
  API — a faithful mirror of uml-viewer's EDN IR (title, packages,
  classes, edges, foreign), plus a `meta` block describing the run.
  """

  alias Umlish.Uml.Schema

  @spec to_map(Schema.t()) :: map()
  def to_map(%Schema{} = schema) do
    %{
      title: schema.title,
      direction: schema.direction,
      packages: Enum.map(schema.packages, &package/1),
      edges: Enum.map(schema.edges, &edge/1),
      foreign: Enum.map(schema.foreign, &class/1),
      meta: schema.meta
    }
  end

  defp package(%Schema.Package{} = p) do
    %{
      id: p.id,
      label: p.label,
      class_count: length(p.classes),
      classes: Enum.map(p.classes, &class/1)
    }
  end

  defp class(%Schema.Class{} = c) do
    %{
      id: c.id,
      name: c.name,
      ns: c.ns,
      package: c.package_id,
      stereotype: c.stereotype,
      lang: c.lang,
      file: c.file,
      fields: Enum.map(c.fields, &%{name: &1.name, type: &1.type}),
      ops:
        Enum.map(c.ops, fn op ->
          %{
            name: op.name,
            args: op.args,
            arity: op.arity,
            visibility: op.visibility,
            returns: op.returns
          }
        end)
    }
  end

  defp edge(%Schema.Edge{} = e) do
    %{
      from: e.from,
      to: e.to,
      kind: e.kind,
      label: e.label,
      # beam introspection has no file, only a compiled line — tolerate
      # evidence maps that carry either key
      evidence: Enum.map(e.evidence || [], &%{file: &1[:file], line: &1[:line]})
    }
  end
end
