defmodule Umlish.Uml.Introspector do
  @moduledoc """
  Live introspection of the running service — the `/api/internals`
  producer. Instead of parsing sources it asks the BEAM what is actually
  loaded right now:

    * modules come from `:code.all_loaded/0`, filtered to this
      application's namespace and build tree
    * ops come from `module_info(:exports)`; argument names, when
      `debug_info` is present, from the beam's abstract code
    * fields come from the module's own `__struct__/0`
    * protocols (`__protocol__/1`) and behaviours (`behaviour_info/1`)
      are `:interface`
    * `__info__(:behaviours)` yields `:implements` edges
    * remote calls in the abstract code yield `:dependency` edges;
      targets outside the application collapse to foreign segments
      (`Phoenix controller` → `Phoenix`)

  This is the web-service analogue of uml-viewer's Clojure "graph of
  the running image": the diagram is true of *this* node, at *this*
  moment — every request re-introspects.
  """

  @behaviour Umlish.Uml.Scanner
  alias Umlish.Uml.Schema

  @app_prefix "Umlish"
  @export_noise MapSet.new([
                  :module_info,
                  :__info__,
                  :__struct__,
                  :__impl__,
                  :impl_for,
                  :impl_for!,
                  :behaviour_info,
                  :__protocol__
                ])

  @impl true
  def scan(_path \\ nil, _opts \\ %{}) do
    modules = app_modules()

    facts = Enum.map(modules, &module_facts/1)
    classes = Enum.map(facts, &Umlish.Uml.Scanner.to_class/1)

    edges =
      Enum.flat_map(facts, fn fact ->
        Enum.map(fact.refs, fn {target, kind, line_no} ->
          %Schema.Edge{from: fact.ns, to: target, kind: kind, evidence: [%{line: line_no}]}
        end)
      end)

    {:ok,
     %{
       title: "umlish — this service, live (#{length(classes)} modules loaded)",
       language: :beam,
       prefixes: %{(@app_prefix <> "Web") => "Web", @app_prefix => "core"},
       classes: classes,
       edges: edges,
       errors: []
     }}
  end

  defp app_modules do
    ensure_app_beams_loaded()

    :code.all_loaded()
    |> Enum.filter(fn {module, loaded_from} -> ours?(module, loaded_from) end)
    |> Enum.map(fn {module, _} -> module end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # BEAM loads lazily — without this, /internals would only show the
  # modules some request happened to touch. Load every beam in our ebin
  # first so the diagram is the whole application, as built.
  defp ensure_app_beams_loaded do
    with beam when is_list(beam) <- :code.which(Umlish.Application),
         ebin = :filename.dirname(beam),
         {:ok, beams} <- :file.list_dir(ebin) do
      beams
      |> Enum.filter(&(to_string(&1) |> String.ends_with?(".beam")))
      |> Enum.each(fn beam_file ->
        base = beam_file |> to_string() |> String.trim_trailing(".beam")

        if String.starts_with?(base, "Elixir.") do
          base |> String.to_atom() |> :code.ensure_loaded()
        end
      end)
    else
      _ -> :ok
    end
  end

  defp ours?(module, loaded_from) do
    name = module_name(module)

    app_namespaced? =
      name == @app_prefix or String.starts_with?(name, @app_prefix <> ".") or
        name == @app_prefix <> "Web" or String.starts_with?(name, @app_prefix <> "Web.")

    app_namespaced? and own_path?(loaded_from)
  end

  defp module_name(module) do
    module |> to_string() |> String.trim_leading("Elixir.")
  end

  # Beam files of this app live under `<build>/lib/umlish/ebin`; code
  # loaded straight from source (iex) appears as .ex paths. Either way the
  # path itself must mention this app — dependency ebins do not.
  defp own_path?(loaded_from) when is_list(loaded_from) do
    String.contains?(to_string(loaded_from), "umlish")
  end

  defp own_path?(_preloaded), do: false

  defp module_facts(module) do
    name = module_name(module)
    exports = safe_exports(module)
    abstract = abstract_forms(module)

    %{
      ns: name,
      stereotype: stereotype(module, exports),
      lang: :beam,
      file: nil,
      fields: struct_fields(module),
      ops: ops(module, exports, abstract),
      refs: refs(module, name, abstract)
    }
  end

  defp safe_exports(module) do
    try do
      module.module_info(:exports)
    rescue
      _ -> []
    end
  end

  defp stereotype(_module, exports) do
    cond do
      {:__protocol__, 1} in exports -> :interface
      {:behaviour_info, 1} in exports -> :interface
      true -> :class
    end
  end

  defp struct_fields(module) do
    defaults =
      try do
        apply(module, :__struct__, [])
      rescue
        _ -> nil
      end

    case defaults do
      %_{} = struct ->
        struct
        |> Map.from_struct()
        |> Map.delete(:__struct__)
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map(fn {name, default} ->
          %{name: to_string(name), type: literal_type(default)}
        end)

      _ ->
        []
    end
  end

  defp ops(_module, exports, abstract) do
    exports
    |> Enum.reject(fn {name, _arity} -> name in @export_noise end)
    |> Enum.sort()
    |> Enum.map(fn {name, arity} ->
      args = abstract_args(abstract, name, arity)
      %{name: to_string(name), args: args, arity: arity, visibility: :public}
    end)
  end

  defp refs(module, own_ns, abstract) do
    behaviour_refs =
      module
      |> behaviours()
      |> Enum.map(&{module_name(&1), :implements})

    call_refs =
      abstract
      |> remote_call_mods()
      |> Enum.reject(fn {mod, _line} -> mod == module end)
      |> Enum.map(fn {mod, line} -> {module_name(mod), :dependency, line} end)

    behaviour_refs = Enum.map(behaviour_refs, fn {target, kind} -> {target, kind, nil} end)

    (behaviour_refs ++ call_refs)
    |> Enum.uniq()
    |> Enum.reject(fn {target, _, _} -> target == own_ns or target == "" end)
  end

  defp behaviours(module) do
    try do
      apply(module, :__info__, [:behaviours]) || []
    rescue
      _ -> []
    end
  end

  # -- abstract code -------------------------------------------------------

  defp abstract_forms(module) do
    case :code.which(module) do
      beam when is_list(beam) ->
        case :beam_lib.chunks(beam, [:abstract_code]) do
          {:ok, {_, [{:abstract_code, {:raw_abstract_v1, forms}}]}} -> forms
          _ -> []
        end

      _ ->
        []
    end
  end

  # Argument names from the first clause of each function.
  defp abstract_args([], _name, _arity), do: []

  defp abstract_args(forms, name, arity) do
    forms
    |> Enum.find(fn
      {:function, _, f, a, _clauses} -> f == name and a == arity
      _ -> false
    end)
    |> case do
      {:function, _, _, _, [{:clause, _, args, _, _} | _]} -> Enum.map(args, &var_name/1)
      _ -> []
    end
  end

  # Abstract-code vars carry compiler suffixes (`changed@1`, `_@2`);
  # show the source name, `_` for ignored args.
  defp var_name({:var, _, name}) do
    base = name |> to_string() |> String.split("@") |> hd()

    cond do
      base == "_" -> "_"
      String.starts_with?(base, "_") -> String.trim_leading(base, "_")
      true -> base
    end
  end

  defp var_name({:atom, _, value}), do: inspect(value)
  defp var_name(_other), do: "arg"

  defp remote_call_mods(forms) do
    forms
    |> Enum.reduce([], &collect_remote/2)
    |> Enum.uniq()
  end

  defp collect_remote({:call, anno, {:remote, _, {:atom, _, module}, _fun}, _args}, acc)
       when is_atom(module),
       do: [{module, :erl_anno.line(anno)} | acc]

  defp collect_remote(node, acc) when is_tuple(node),
    do: node |> Tuple.to_list() |> Enum.reduce(acc, &collect_remote/2)

  defp collect_remote(node, acc) when is_list(node),
    do: Enum.reduce(node, acc, &collect_remote/2)

  defp collect_remote(_leaf, acc), do: acc

  defp literal_type(v) when is_integer(v), do: "integer"
  defp literal_type(v) when is_float(v), do: "float"
  defp literal_type(v) when is_binary(v), do: "String.t"
  defp literal_type(true), do: "boolean"
  defp literal_type(false), do: "boolean"
  defp literal_type(nil), do: "nil"
  defp literal_type(v) when is_atom(v), do: ":#{v}"
  defp literal_type(v) when is_list(v), do: "list"
  defp literal_type(v) when is_map(v), do: "map"
  defp literal_type(_), do: nil
end
