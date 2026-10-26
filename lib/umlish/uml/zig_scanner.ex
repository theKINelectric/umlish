defmodule Umlish.Uml.ZigScanner do
  @moduledoc """
  Scans a Zig project into UML facts (one class per source file), after
  uml-viewer's Rust/TypeScript rules adapted to Zig:

    * every `.zig` file in the tree is a class; `pub fn` are its ops
      (a plain `fn` is not drawn, matching uml-viewer's `defn-` /
      `pub(crate)` conventions)
    * `pub const X = struct/enum/union/opaque` become fields of that type
    * `@import("relative.zig")` is a `:dependency` on that file
    * `@import("name")` matching an `addModule("name", root)` in
      `build.zig` is a `:dependency` on the module's root file
    * anything else (`std`, `builtin`, …) is foreign

  Class `ns` is the project-relative path itself (`src/workbench/flow.zig`)
  and the class id is that path dotted — unique even when two trees have
  files with the same basename. The namespace prefixes used for grouping
  run up to and including the last `src`/`lib` path component, so
  `src/workbench/flow.zig` groups under `workbench` and
  `apps/amrita/src/tests.zig` under that tree's `src`.
  """

  @behaviour Umlish.Uml.Scanner
  alias Umlish.Uml.Schema

  @skip_dirs [".zig-cache", "zig-out", ".git", "node_modules", "deps", ".cache"]
  @max_files 10_000
  @max_file_bytes 1_000_000
  @root_markers ["src", "lib"]

  @pub_fn ~r/\bpub\s+fn\s+([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([^)]*)/
  @pub_type ~r/\bpub\s+const\s+([a-zA-Z_][a-zA-Z0-9_]*)[^=]*=\s*(?:(?:packed|extern)\s+)?(struct|enum|union|opaque)\b/
  @import ~r/@import\(\s*"([^"]+)"\s*\)/

  @impl true
  def scan(path, opts \\ %{}) do
    path = Path.expand(path)
    scope = if Map.get(opts, :scope) == :all, do: :all, else: :src_roots

    with :ok <- check_dir(path) do
      modules = read_build_modules(path)
      {files, truncated?} = zig_files(path, scope)

      if files == [] do
        {:error, {:no_zig_sources, path}}
      else
        {classes, edges, read_errors} = parse_files(path, files, modules)
        prefixes = namespace_prefixes(files)

        errors =
          read_errors ++
            if truncated?,
              do: ["file cap of #{@max_files} hit — the tree was truncated"],
              else: []

        {:ok,
         %{
           title: "#{Path.basename(path)} (Zig sources)",
           language: :zig,
           prefixes: prefixes,
           classes: classes,
           edges: edges,
           errors: errors
         }}
      end
    end
  end

  defp check_dir(path) do
    if File.dir?(path), do: :ok, else: {:error, {:not_a_directory, path}}
  end

  # addModule("honeybadger", .{ .root_source_file = b.path("src/framework.zig") })
  # String-scanned rather than regexed: the call spans many lines and
  # nests parentheses.
  defp read_build_modules(path) do
    case File.read(Path.join(path, "build.zig")) do
      {:ok, source} ->
        source
        |> String.split("addModule(")
        |> tl()
        |> Enum.reduce(%{}, fn chunk, acc ->
          with {:ok, name} <- first_quoted(chunk),
               root_chunk when is_binary(root_chunk) <- after_token(chunk, "root_source_file"),
               {:ok, root} <- first_quoted(root_chunk) do
            Map.put(acc, name, root)
          else
            _ -> acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp first_quoted(chunk) do
    case Regex.run(~r/"([^"]+)"/, chunk, capture: :all_but_first) do
      [quoted] -> {:ok, quoted}
      _ -> :error
    end
  end

  defp after_token(chunk, token) do
    case :binary.split(chunk, token) do
      [_, rest] -> rest
      [_] -> nil
    end
  end

  # Default scope walks the project's own source roots (`src/`, `lib/`
  # at the top level) — the product code, uml-viewer style. `:all` walks
  # the whole tree (experiments, vendored apps and all); big repositories
  # like honey_badger carry thousands of exploratory files outside src.
  defp zig_files(path, scope) do
    roots =
      case scope do
        :src_roots -> Enum.map(@root_markers, &Path.join(path, &1))
        :all -> [path]
      end

    root_dirs = Enum.filter(roots, &File.dir?/1)

    dirs = if root_dirs == [] and scope == :src_roots, do: [path], else: root_dirs

    dirs
    |> Enum.reduce({[], false, @max_files}, fn dir, {files, truncated?, budget} ->
      rel_root = Path.relative_to(dir, path)
      {found, remaining} = walk(dir, if(rel_root in [path, "."], do: "", else: rel_root), budget)
      {files ++ found, truncated? or remaining == 0, remaining}
    end)
    |> then(fn {files, truncated?, _remaining} ->
      # Budget is shared across roots so the cap bounds discovery itself.
      {Enum.uniq(files), truncated?}
    end)
  end

  # Depth-first with a shared budget: once it hits zero the walk stops
  # descending, so a giant tree never fully unrolls before the cap applies.
  defp walk(_dir, _rel, budget) when budget <= 0, do: {[], 0}

  defp walk(dir, rel, budget) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, {[], budget}, fn entry, {files, remaining} ->
          full = Path.join(dir, entry)
          rel_entry = if(rel == "", do: entry, else: rel <> "/" <> entry)

          cond do
            remaining <= 0 ->
              {files, remaining}

            entry in @skip_dirs ->
              {files, remaining}

            # Symlinked directories can loop forever; File.dir?/1 follows
            # them, so check the link itself before descending.
            File.lstat(full) == {:ok, %File.Stat{type: :symlink}} ->
              {files, remaining}

            File.dir?(full) ->
              {found, left} = walk(full, rel_entry, remaining)
              {files ++ found, left}

            String.ends_with?(entry, ".zig") ->
              {files ++ [rel_entry], remaining - 1}

            true ->
              {files, remaining}
          end
        end)

      _ ->
        {[], budget}
    end
  end

  # Distinct prefixes, each running up to and including the last
  # src/lib marker on the file's path ("src", "apps.amrita.src"), mapped
  # to the fallback package for files sitting directly in that root.
  defp namespace_prefixes(files) do
    files
    |> Enum.reduce(%{}, fn rel, acc ->
      case root_prefix(rel) do
        nil -> acc
        "src" -> Map.put(acc, "src", "core")
        prefix -> Map.put_new(acc, prefix, prefix |> String.split(".") |> List.last())
      end
    end)
  end

  defp root_prefix(rel) do
    components = Path.split(rel)

    case Enum.find_index(Enum.reverse(components), &(&1 in @root_markers)) do
      nil ->
        nil

      rev_index ->
        take = length(components) - rev_index
        components |> Enum.take(take) |> Enum.join(".")
    end
  end

  # Module names → their root file (normalized: build.zig may write
  # "./src/x.zig" for what the walker records as "src/x.zig"), so
  # `@import("honeybadger")` can be retargeted to the root file's ns.
  defp parse_files(root, files, modules) do
    module_roots =
      Map.new(modules, fn {name, root} ->
        {name, root |> Path.expand("/") |> String.trim_leading("/")}
      end)

    {facts, errors} =
      files
      |> Task.async_stream(&parse_file(root, &1, module_roots), timeout: 30_000, ordered: false)
      |> Enum.reduce({[], []}, fn
        {:ok, fact}, {facts, errs} -> {[fact | facts], errs}
        {:exit, reason}, {facts, errs} -> {facts, ["task exit: #{inspect(reason)}" | errs]}
      end)

    # ordered: false above — sort for deterministic documents.
    facts = Enum.sort_by(facts, & &1.ns)
    errors = Enum.sort(errors)

    classes = Enum.map(facts, &Umlish.Uml.Scanner.to_class/1)

    edges =
      Enum.flat_map(facts, fn fact ->
        for {target, kind, line_no} <- fact.refs do
          %Schema.Edge{
            from: fact.ns,
            to: target,
            kind: kind,
            evidence: [%{file: fact.ns, line: line_no}]
          }
        end
      end)

    {classes, edges, errors}
  end

  # Unreadable or oversized files still appear — as empty classes, so
  # the diagram shows the file exists even when its text could not be read.
  defp parse_file(root, rel, module_roots) do
    source =
      case File.read(Path.join(root, rel)) do
        {:ok, binary} when byte_size(binary) <= @max_file_bytes -> binary
        _ -> ""
      end

    ops =
      for [name, params] <- Regex.scan(@pub_fn, source, capture: :all_but_first) do
        %{name: name, args: param_names(params), arity: arity_of(params), visibility: :public}
      end
      |> Enum.uniq_by(& &1.name)
      |> Enum.sort_by(& &1.name)

    fields =
      for [name, kind] <- Regex.scan(@pub_type, source, capture: :all_but_first) do
        %{name: name, type: kind}
      end
      |> Enum.uniq_by(& &1.name)

    # Scan imports line by line so every ref carries its source line —
    # also immune to a `@import` inside a longer line's other parens.
    refs =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {text, line_no} ->
        for [spec] <- Regex.scan(@import, text, capture: :all_but_first) do
          {resolve_import(spec, rel, module_roots), :dependency, line_no}
        end
      end)
      |> Enum.uniq_by(fn {target, _kind, line_no} -> {target, line_no} end)

    %{
      ns: rel,
      name: rel |> Path.basename(".zig") |> Schema.prettify(),
      stereotype: :class,
      lang: :zig,
      file: rel,
      fields: fields,
      ops: ops,
      refs: refs
    }
  end

  defp resolve_import(spec, from_rel, module_roots) do
    cond do
      String.ends_with?(spec, ".zig") ->
        joined = from_rel |> Path.dirname() |> Path.join(spec)

        joined
        |> Path.expand("/")
        |> String.trim_leading("/")

      Map.has_key?(module_roots, spec) ->
        Map.get(module_roots, spec)

      true ->
        # `std`, `builtin`, … — not a project class downstream → foreign
        spec
    end
  end

  defp param_names(params) do
    params
    |> String.split(",", trim: true)
    |> Enum.map(fn param ->
      param
      |> String.split(":", parts: 2)
      |> hd()
      |> String.trim()
      |> case do
        "" -> "_"
        name -> name
      end
    end)
  end

  defp arity_of(params) do
    params |> String.split(",", trim: true) |> Enum.reject(&(&1 == "")) |> length()
  end
end
