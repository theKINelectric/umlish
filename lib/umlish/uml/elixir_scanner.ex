defmodule Umlish.Uml.ElixirScanner do
  @moduledoc """
  Scans an Elixir project's sources into UML facts (one class per module).

  Reads the AST of every `.ex` under `lib/` (and `apps/*/lib/` for
  umbrellas), following uml-viewer's Clojure rules translated to Elixir:

    * `defprotocol` and modules declaring `@callback` are `:interface`
    * `@behaviour` and `defimpl` produce `:implements` edges
    * `use`/`import`/`require`/`alias` and remote calls produce
      `:dependency` edges (aliases are resolved, `alias Foo.{Bar,Baz}`
      included)
    * `defstruct`/`defexception` supply fields; `def`/`defp`/`defmacro`
      heads supply ops
    * references that leave the project collapse to foreign classes
      (`Phoenix.LiveView` → `Phoenix`); a unique-suffix match
      (`Repo` → `MyApp.Repo`) resolves back into the project

  The app name comes from `mix.exs` (`app: :foo`); the namespace
  prefixes stripped for ids are `Foo` and `FooWeb`.
  """

  @behaviour Umlish.Uml.Scanner
  alias Umlish.Uml.Schema

  @max_file_bytes 1_000_000
  @def_heads [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp]

  @impl true
  def scan(path, _opts \\ %{}) do
    path = Path.expand(path)

    with :ok <- check_dir(path) do
      app_name = detect_app(path)
      root = Macro.camelize(app_name)
      prefixes = %{(root <> "Web") => "Web", root => "core"}
      {facts, errors} = path |> elixir_files() |> parse_files()

      # Evidence paths read best project-relative (portable snapshots).
      facts = Enum.map(facts, &%{&1 | file: Path.relative_to(&1.file, path)})

      {classes, edges} = build(facts)

      {:ok,
       %{
         title: "#{root} (Elixir sources)",
         language: :elixir,
         prefixes: prefixes,
         classes: classes,
         edges: edges,
         errors: Enum.map(errors, &format_error/1)
       }}
    end
  end

  defp check_dir(path) do
    if File.dir?(path), do: :ok, else: {:error, {:not_a_directory, path}}
  end

  defp detect_app(path) do
    case File.read(Path.join(path, "mix.exs")) do
      {:ok, source} ->
        case Regex.run(~r/app\s*:\s*:([a-z_][a-z0-9_]*)/, source, capture: :all_but_first) do
          [app] -> app
          _ -> fallback_app(path)
        end

      _ ->
        fallback_app(path)
    end
  end

  defp fallback_app(path) do
    path |> Path.basename() |> String.replace(~r/[^a-z0-9_]/, "_")
  end

  defp elixir_files(path) do
    ["lib/**/*.ex", "apps/*/lib/**/*.ex"]
    |> Enum.flat_map(&Path.wildcard(Path.join(path, &1)))
    |> Enum.uniq()
    |> Enum.reject(&too_big/1)
  end

  defp too_big(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size > @max_file_bytes
      _ -> true
    end
  end

  defp parse_files(files) do
    files
    |> Task.async_stream(&parse_file/1, timeout: 30_000, ordered: false)
    |> Enum.reduce({[], []}, fn
      {:ok, {:ok, facts}}, {ok, errs} -> {ok ++ facts, errs}
      {:ok, {:error, {file, reason}}}, {ok, errs} -> {ok, [{file, reason} | errs]}
      {:exit, reason}, {ok, errs} -> {ok, [{"task", inspect(reason)} | errs]}
    end)
  end

  defp parse_file(path) do
    case File.read(path) do
      {:ok, source} ->
        case Code.string_to_quoted(source, file: path) do
          {:ok, ast} ->
            {:ok, collect_modules(ast, nil, [], path)}

          {:error, {line, error, token}} ->
            {:error, {path, "line #{line}: #{inspect(error)} #{inspect(token)}"}}
        end

      _ ->
        {:error, {path, "unreadable"}}
    end
  end

  defp format_error({file, reason}), do: "#{file}: #{reason}"
  defp format_error(other), do: inspect(other)

  # -- module collection ----------------------------------------------------

  defp collect_modules({:defmodule, _meta, [head, [do: body]]}, prefix, acc, file) do
    case module_name(head, prefix) do
      nil -> collect_modules(body, prefix, acc, file)
      name -> collect_modules(body, name, [module_facts(name, body, file) | acc], file)
    end
  end

  defp collect_modules({:defprotocol, _meta, [head, [do: body]]}, prefix, acc, file) do
    case module_name(head, prefix) do
      nil -> acc
      name -> [module_facts(name, body, file, :interface) | acc]
    end
  end

  defp collect_modules({:defimpl, _meta, [proto | rest]}, prefix, acc, file) do
    # Quoted defimpl splits its keywords: [proto, [for: …], [do: body]].
    opts = List.flatten(rest)
    body = Keyword.get(opts, :do)
    acc = [impl_facts(proto, opts, file, prefix) | acc]
    collect_modules(body || {}, prefix, acc, file)
  end

  defp collect_modules({:__block__, _meta, exprs}, prefix, acc, file) do
    Enum.reduce(exprs, acc, &collect_modules(&1, prefix, &2, file))
  end

  defp collect_modules(_node, _prefix, acc, _file), do: acc

  defp module_name({:__aliases__, _m, parts}, prefix) when is_list(parts) do
    case alias_segments(parts, prefix) do
      {:absolute, parts} -> Enum.join(parts, ".")
      {:relative, parts} when is_binary(prefix) -> Enum.join([prefix | parts], ".")
      {:relative, parts} -> Enum.join(parts, ".")
      :error -> nil
    end
  end

  defp module_name(atom, prefix) when is_atom(atom) and not is_boolean(atom) do
    name = to_string(atom)
    if prefix, do: prefix <> "." <> name, else: name
  end

  defp module_name(_, _), do: nil

  defp impl_facts(proto, opts, file, prefix) do
    for_ns =
      case Keyword.get(opts, :for) do
        {:__MODULE__, _, ctx} when is_atom(ctx) and is_binary(prefix) -> prefix
        target -> alias_to_string(target, prefix)
      end || "Impl"

    proto_ns = alias_to_string(proto, prefix) || "Protocol"
    proto_ns = if prefix, do: prefix <> "." <> proto_ns, else: proto_ns
    ns = "#{proto_ns}.#{for_ns}"

    %{
      ns: ns,
      stereotype: :class,
      lang: :elixir,
      file: file,
      fields: [],
      ops: impl_ops(Keyword.get(opts, :do)),
      refs: [{proto_ns, :implements, nil}]
    }
  end

  defp impl_ops(nil), do: []

  defp impl_ops(body) do
    body
    |> deep_filter(&match?({kind, _, _} when kind in @def_heads, &1))
    |> Enum.map(&head_op(&1, :def))
    |> dedup_ops()
  end

  # -- per-module fact extraction --------------------------------------------

  defp module_facts(ns, body, file, stereotype \\ nil) do
    state = %{
      module: ns,
      aliases: %{},
      fields: [],
      ops: [],
      refs: [],
      interface?: stereotype == :interface
    }

    state = walk_facts(body, state)

    %{
      ns: ns,
      stereotype: final_stereotype(state),
      lang: :elixir,
      file: file,
      fields: state.fields,
      ops: dedup_ops(state.ops),
      refs: state.refs
    }
  end

  defp final_stereotype(%{interface?: true}), do: :interface
  defp final_stereotype(_), do: :class

  defp walk_facts({:__block__, _m, exprs}, state) do
    Enum.reduce(exprs, state, &walk_facts/2)
  end

  # Nested modules/protocols/impls are their own classes; their
  # internals belong there, not in the enclosing module.
  defp walk_facts({kind, _, _}, state) when kind in [:defmodule, :defprotocol, :defimpl],
    do: state

  # Aliases both register the name mapping and count as a dependency on
  # the target (same as Clojure's require), matching the moduledoc.
  # `alias __MODULE__.{A, B}` puts a bare `__MODULE__` before the dot,
  # not an `__aliases__` node.
  defp walk_facts(
         {:alias, meta, [{{:., m, [{:__MODULE__, _, ctx} = base, :{}]}, mm, members}]},
         state
       )
       when is_atom(ctx) do
    walk_facts(
      {:alias, meta, [{{:., m, [{:__aliases__, [], [base]}, :{}]}, mm, members}]},
      state
    )
  end

  defp walk_facts(
         {:alias, meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, members}]},
         state
       ) do
    line = line(meta)

    case alias_segments(base, state.module) do
      :error ->
        state

      {_, base} ->
        {aliases, refs} =
          Enum.reduce(members, {state.aliases, state.refs}, fn
            {:__aliases__, _, parts}, {acc, refs} ->
              case alias_segments(parts, nil) do
                {:relative, parts} ->
                  {Map.put(acc, List.last(parts), base ++ parts),
                   [{Enum.join(base ++ parts, "."), :dependency, line} | refs]}

                _ ->
                  {acc, refs}
              end

            _other, acc ->
              acc
          end)

        %{state | aliases: aliases, refs: refs}
    end
  end

  defp walk_facts({:alias, meta, [{:__aliases__, _, parts}, opts]}, state) when is_list(opts) do
    case alias_segments(parts, state.module) do
      :error ->
        state

      {_, parts} ->
        key =
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as | _]} when is_atom(as) -> to_string(as)
            _ -> List.last(parts)
          end

        state = %{state | aliases: Map.put(state.aliases, key, parts)}
        %{state | refs: [{Enum.join(parts, "."), :dependency, line(meta)} | state.refs]}
    end
  end

  defp walk_facts({:alias, meta, [{:__aliases__, _, parts}]}, state) do
    case alias_segments(parts, state.module) do
      :error ->
        state

      {_, parts} ->
        state = %{state | aliases: Map.put(state.aliases, List.last(parts), parts)}
        %{state | refs: [{Enum.join(parts, "."), :dependency, line(meta)} | state.refs]}
    end
  end

  defp walk_facts({:defdelegate, meta, [head | rest]}, state) do
    # Quoted keywords nest one level: [head, [to: Target]].
    opts = List.flatten(rest)
    {name, args} = head_name_args(head)

    state = %{
      state
      | ops: [%{name: name, args: args, arity: length(args), visibility: :public} | state.ops]
    }

    case Keyword.get(opts, :to) do
      nil -> state
      target -> add_ref(state, target, :dependency, line(meta))
    end
  end

  defp walk_facts({:use, meta, [target | _]}, state),
    do: add_ref(state, target, :dependency, line(meta))

  defp walk_facts({:import, meta, [target | _]}, state),
    do: add_ref(state, target, :dependency, line(meta))

  defp walk_facts({:require, meta, [target | _]}, state),
    do: add_ref(state, target, :dependency, line(meta))

  defp walk_facts({:@, meta, [{attr, _, [target]}]}, state) when attr in [:behaviour, :behavior],
    do: add_ref(state, target, :implements, line(meta))

  defp walk_facts({:@, _, [{attr, _, _}]}, state) when attr in [:callback, :macrocallback],
    do: %{state | interface?: true}

  defp walk_facts({:defstruct, _, [fields]}, state),
    do: %{state | fields: state.fields ++ struct_fields(fields)}

  defp walk_facts({:defexception, _, [fields]}, state),
    do: %{state | fields: state.fields ++ struct_fields(fields)}

  # Record the op, then keep walking: the body carries remote calls and
  # struct patterns that are references too.
  defp walk_facts({kind, _, _} = node, state) when kind in @def_heads do
    state = %{state | ops: [head_op(node, kind) | state.ops]}
    node |> Tuple.to_list() |> tl() |> Enum.reduce(state, &walk_facts/2)
  end

  # A bare alias used as a value (`scanner = ZigScanner`, cond branches)
  # is a dependency too — no call required.
  defp walk_facts({:__aliases__, meta, _parts} = node, state) do
    state = add_ref(state, node, :dependency, line(meta))
    node |> Tuple.to_list() |> tl() |> Enum.reduce(state, &walk_facts/2)
  end

  # Struct references %Mod{...} — the most common cross-module tie in
  # Phoenix code. Recurse into the map: values may hold more refs.
  defp walk_facts({:%, meta, [target, {:%{}, _, kvs}]}, state) do
    state = add_ref(state, target, :dependency, line(meta))
    Enum.reduce(kvs, state, &walk_facts/2)
  end

  defp walk_facts({:%{}, _, kvs}, state), do: Enum.reduce(kvs, state, &walk_facts/2)

  # Remote member access Mod.fun / :mod.fun — the dot node alone names
  # the module; call arguments may hold further references.
  defp walk_facts({:., meta, [{:__aliases__, _, parts}, _fun]} = node, state) do
    state = add_ref(state, {:__aliases__, [], parts}, :dependency, line(meta))
    node |> Tuple.to_list() |> tl() |> Enum.reduce(state, &walk_facts/2)
  end

  defp walk_facts({:., meta, [target, _fun]} = node, state) when is_atom(target) do
    state = add_ref(state, target, :dependency, line(meta))
    node |> Tuple.to_list() |> tl() |> Enum.reduce(state, &walk_facts/2)
  end

  defp walk_facts(node, state) when is_tuple(node),
    do: node |> Tuple.to_list() |> Enum.reduce(state, &walk_facts/2)

  defp walk_facts(node, state) when is_list(node),
    do: Enum.reduce(node, state, &walk_facts/2)

  defp walk_facts(_leaf, state), do: state

  defp add_ref(state, {:__aliases__, _, parts}, kind, line) do
    case alias_segments(parts, state.module) do
      {:relative, parts} ->
        resolved = resolve_alias(parts, state.aliases)
        %{state | refs: [{Enum.join(resolved, "."), kind, line} | state.refs]}

      {:absolute, parts} ->
        %{state | refs: [{Enum.join(parts, "."), kind, line} | state.refs]}

      :error ->
        state
    end
  end

  defp add_ref(state, target, kind, line) when is_atom(target) and not is_nil(target),
    do: %{state | refs: [{mod_string(target), kind, line} | state.refs]}

  defp add_ref(state, _other, _kind, _line), do: state

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line)
  defp line(_), do: nil

  # `:Enum |> to_string/1` is "Elixir.Enum"; `__aliases__` parts carry no
  # prefix. Normalize atom module refs onto the same dotted form.
  defp mod_string(atom) do
    case to_string(atom) do
      "Elixir." <> rest -> rest
      erlang -> erlang
    end
  end

  defp resolve_alias(parts, aliases) do
    case Map.fetch(aliases, hd(parts)) do
      {:ok, target} -> target ++ tl(parts)
      :error -> parts
    end
  end

  defp alias_to_string({:__aliases__, _, parts}, current) do
    case alias_segments(parts, current) do
      {_, parts} -> Enum.join(parts, ".")
      :error -> nil
    end
  end

  defp alias_to_string(atom, _current) when is_atom(atom) and not is_nil(atom),
    do: mod_string(atom)

  defp alias_to_string(_, _current), do: nil

  # Alias parts are atoms, except the head may be an expression:
  # `__MODULE__.Sub` quotes as [{:__MODULE__, meta, ctx}, :Sub] and names
  # the enclosing module. Other heads (`@mod.Sub`, `unquote(m).Sub`) are
  # not statically resolvable and yield no reference.
  defp alias_segments([{:__MODULE__, _, ctx} | rest], current)
       when is_atom(ctx) and is_binary(current) do
    if Enum.all?(rest, &is_atom/1),
      do: {:absolute, String.split(current, ".") ++ Enum.map(rest, &to_string/1)},
      else: :error
  end

  defp alias_segments(parts, _current) do
    if Enum.all?(parts, &is_atom/1),
      do: {:relative, Enum.map(parts, &to_string/1)},
      else: :error
  end

  # -- def heads → ops ---------------------------------------------------------

  # [head, body] for ordinary defs; bare [head] for bodiless protocol
  # and callback declarations.
  defp head_op({_, _, [head | _]}, kind) do
    {name, args} = head_name_args(head)

    %{
      name: name,
      args: args,
      arity: length(args),
      visibility: if(kind in [:defp, :defmacrop], do: :private, else: :public)
    }
  end

  defp head_name_args({:when, _, [head | _guards]}), do: head_name_args(head)

  defp head_name_args({name, _, args}) when is_atom(name),
    do: {to_string(name), Enum.map(args || [], &pattern_label/1)}

  defp head_name_args(name) when is_atom(name), do: {to_string(name), []}

  # Macro-generated heads (`def unquote(name)(a)`) — the name is not an
  # atom at this point; keep the op with a placeholder instead of
  # dropping the whole file.
  defp head_name_args({_, _, args}), do: {"unquote", Enum.map(args || [], &pattern_label/1)}
  defp head_name_args(_), do: {"unquote", []}

  defp pattern_label({name, _, nil}) when is_atom(name), do: to_string(name)
  defp pattern_label({_op, _, [left, _right]}), do: pattern_label(left)
  defp pattern_label({_kind, _, _children}), do: "pat"
  defp pattern_label(lit) when is_atom(lit) or is_number(lit) or is_binary(lit), do: "lit"
  defp pattern_label(_other), do: "pat"

  defp dedup_ops(ops) do
    ops
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1.name, &1.arity})
    |> Enum.sort_by(& &1.name)
  end

  # -- defstruct → fields --------------------------------------------------------

  defp struct_fields(fields) when is_list(fields) do
    fields
    |> Enum.map(fn
      {name, default} -> %{name: to_string(name), type: literal_type(default)}
      name when is_atom(name) -> %{name: to_string(name), type: nil}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp struct_fields(_), do: []

  defp literal_type(v) when is_integer(v), do: "integer"
  defp literal_type(v) when is_float(v), do: "float"
  defp literal_type(v) when is_binary(v), do: "String.t"
  defp literal_type(true), do: "boolean"
  defp literal_type(false), do: "boolean"
  defp literal_type(nil), do: "nil"
  defp literal_type(v) when is_atom(v), do: ":#{v}"
  defp literal_type(v) when is_list(v), do: "list"
  defp literal_type(v) when is_map(v), do: "map"

  defp literal_type({:%, _, [{:__aliases__, _, parts}, _]}),
    do: Enum.map_join(parts, ".", &to_string/1)

  defp literal_type(_), do: nil

  # -- deep helper ------------------------------------------------------------------

  defp deep_filter(node, pred, acc \\ []) do
    acc = if pred.(node), do: [node | acc], else: acc

    cond do
      is_tuple(node) -> node |> Tuple.to_list() |> Enum.reduce(acc, &deep_filter(&1, pred, &2))
      is_list(node) -> Enum.reduce(node, acc, &deep_filter(&1, pred, &2))
      true -> acc
    end
  end

  # -- fact assembly ------------------------------------------------------------------

  defp build(facts) do
    classes =
      facts
      |> Enum.uniq_by(& &1.ns)
      |> Enum.sort_by(& &1.ns)
      |> Enum.map(&Umlish.Uml.Scanner.to_class/1)

    nss = MapSet.new(classes, & &1.ns)

    edges =
      Enum.flat_map(facts, fn fact ->
        Enum.map(fact.refs, fn {target, kind, line} ->
          %Schema.Edge{
            from: fact.ns,
            to: resolve_target(target, nss),
            kind: kind,
            evidence: [%{file: fact.file, line: line}]
          }
        end)
      end)

    {classes, edges}
  end

  # `Repo` resolves back into the project when exactly one module has
  # that suffix (`MyApp.Repo`); ambiguous or unknown names stay as-is
  # and are treated as foreign downstream. A name the runtime already
  # knows (`GenServer`, `Supervisor`) is that module, even when a project
  # module shares its last segment (`FlowExtra.Sync.GenServer`).
  defp resolve_target(target, nss) do
    cond do
      MapSet.member?(nss, target) ->
        target

      known_module?(target) ->
        target

      true ->
        candidates = Enum.filter(nss, &String.ends_with?(&1, "." <> target))

        case candidates do
          [only] -> only
          _ -> target
        end
    end
  end

  # Only existing atoms: scanned names must not grow the atom table.
  defp known_module?(name) do
    String.to_existing_atom("Elixir." <> name) |> Code.ensure_loaded?()
  rescue
    ArgumentError -> false
  end
end
