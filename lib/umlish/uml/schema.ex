defmodule Umlish.Uml.Schema do
  @moduledoc """
  The UML intermediate representation (IR) this service produces.

  Modeled on the EDN IR of unclebob/uml-viewer: a document carries a
  `title`, a list of `packages` (components), the `classes` inside them,
  the `edges` between classes, and `foreign` classes for external
  libraries that are referenced but not part of the project.

  Identity rules shared by every producer (scanners + introspector):

    * a class `ns` is the language's own module identifier
      (`Umlish.Uml.ZigScanner`, `src/workbench/flow.zig`)
    * a class `id` is that ns in canonical dotted form — always the full
      namespace, never truncated, so files with the same basename in
      different trees never collide
    * `classify/2` derives the package (component) from the segments
      after the project prefix: `Umlish.Uml.ZigScanner` → `Uml`,
      `src.workbench.flow` → `workbench`
    * edge kinds follow uml-viewer: `:dependency`, `:implements`,
      `:inheritance`, `:association`, `:aggregation`, `:composition`
  """

  @type stereotype :: :class | :interface | :abstract | :enumeration | nil
  @type edge_kind ::
          :dependency | :implements | :inheritance | :association | :aggregation | :composition
  @type visibility :: :public | :private

  defmodule Op do
    @moduledoc "A member function. `args` are display names; `arity` is authoritative."
    defstruct [:name, args: [], arity: 0, visibility: :public, returns: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Field do
    @moduledoc "A member attribute."
    defstruct [:name, type: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Class do
    @moduledoc "One UML class (a module or a source file in the tree)."
    defstruct [
      :id,
      :name,
      :ns,
      :package_id,
      stereotype: :class,
      lang: nil,
      file: nil,
      fields: [],
      ops: []
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Package do
    @moduledoc "A component: a named grouping of classes (a namespace level)."
    defstruct [:id, :label, classes: []]
    @type t :: %__MODULE__{}
  end

  defmodule Edge do
    @moduledoc """
    A relationship between two class ids. `evidence` points at the
    source sites (file + line) that produced the edge, capped per edge.
    """
    defstruct [:from, :to, kind: :dependency, label: nil, evidence: []]
    @type t :: %__MODULE__{}
  end

  defstruct [
    :title,
    direction: :tb,
    packages: [],
    edges: [],
    foreign: [],
    meta: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Classifies a dotted class id against the project's namespace prefixes
  (longest match wins) into `{package_id, rest_segments}`.

  `prefixes` is a map of dotted prefix → fallback package id, used when
  a module's remainder is a single segment (or the bare prefix itself):
  `Umlish.Repo` → the app's own `"core"`, `UmlishWeb.Router` →
  `"Web"`, `src/main.zig` → `"core"`, `apps.amrita.src/tests.zig` →
  that tree's `"src"`.
  """
  @spec classify(String.t(), %{optional(String.t()) => String.t()}) :: {String.t(), [String.t()]}
  def classify(id, prefixes) when is_binary(id) do
    prefix =
      prefixes
      |> Map.keys()
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.find(&(String.starts_with?(id, &1 <> ".") or id == &1))
      |> Kernel.||("")

    rest = strip_prefix(id, prefix) |> String.trim_leading(".")
    segments = String.split(rest, ".", trim: true)

    case segments do
      [] -> {fallback_package(prefix, prefixes), []}
      [only] -> {fallback_package(prefix, prefixes), [only]}
      [package | tail] -> {package, tail}
    end
  end

  defp strip_prefix(id, ""), do: id
  defp strip_prefix(id, prefix), do: String.replace_prefix(id, prefix, "")

  defp fallback_package("", _prefixes), do: "core"

  defp fallback_package(prefix, prefixes),
    do: Map.get(prefixes, prefix) || prefix |> String.split(".") |> List.last()

  @doc "Groups classes into packages by their classified segment, preserving class order."
  @spec group_packages([Class.t()], %{optional(String.t()) => String.t()}) :: [Package.t()]
  def group_packages(classes, prefixes) do
    {packages, order} =
      Enum.reduce(classes, {%{}, []}, fn
        %Class{} = class, {map, order} ->
          {package_id, _} = classify(class.id, prefixes)
          class = %Class{class | package_id: package_id}
          map = Map.update(map, package_id, [class], &[class | &1])
          order = if package_id in order, do: order, else: order ++ [package_id]
          {map, order}
      end)

    Enum.map(order, fn package_id ->
      %Package{
        id: package_id,
        label: prettify(package_id),
        classes: packages |> Map.fetch!(package_id) |> Enum.reverse()
      }
    end)
  end

  @doc "`source-clojure` → `SourceClojure`, matching uml-viewer's title rule."
  @spec prettify(String.t()) :: String.t()
  def prettify(segment) do
    segment
    |> String.split(["-", "_", "."], trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join()
  end

  @doc """
  Deduplicates edges, merging their evidence. `:implements` wins over
  `:dependency` between the same pair.
  """
  @spec dedup_edges([Edge.t()]) :: [Edge.t()]
  def dedup_edges(edges) do
    edges
    |> Enum.reject(fn edge -> edge.from == edge.to end)
    |> Enum.reduce(%{}, fn edge, acc ->
      key = {edge.from, edge.to}
      Map.update(acc, key, edge, &merge_edge(&1, edge))
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.from, &1.to})
  end

  defp merge_edge(%Edge{} = prev, %Edge{} = edge) do
    %Edge{
      prev
      | kind: choose_kind(prev.kind, edge.kind),
        evidence:
          (prev.evidence ++ edge.evidence)
          |> Enum.uniq_by(&{&1[:file], &1[:line]})
          |> Enum.take(10)
    }
  end

  defp choose_kind(:implements, _kind), do: :implements
  defp choose_kind(_kind, :implements), do: :implements
  defp choose_kind(kind, _other), do: kind
end
