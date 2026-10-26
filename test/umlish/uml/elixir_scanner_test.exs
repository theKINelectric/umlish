defmodule Umlish.Uml.ElixirScannerTest do
  use ExUnit.Case, async: true

  alias Umlish.Uml.ElixirScanner

  @proj Path.expand("../../fixtures/elixir_proj", __DIR__)

  test "scans modules, ops, fields, stereotypes and refs" do
    {:ok, scan} = ElixirScanner.scan(@proj, %{})

    by_ns = Map.new(scan.classes, &{&1.ns, &1})

    # one class per module, prefixes from mix.exs
    assert MapSet.subset?(
             MapSet.new([
               "ElixirProj",
               "ElixirProj.Animals.Dog",
               "ElixirProj.Animals.Cat",
               "ElixirProj.Store.Kennel",
               "ElixirProj.Store.Counter",
               "ElixirProj.Store.Stock",
               "ElixirProj.Store.Special",
               "ElixirProj.Store.Special.BitString"
             ]),
             MapSet.new(Map.keys(by_ns))
           )

    assert scan.prefixes == %{"ElixirProjWeb" => "Web", "ElixirProj" => "core"}

    # ops: public defs with args; privates marked
    dog = by_ns["ElixirProj.Animals.Dog"]
    op_names = MapSet.new(dog.ops, & &1.name)
    assert MapSet.subset?(MapSet.new(["speak", "chase", "nap", "secret"]), op_names)
    assert Enum.find(dog.ops, &(&1.name == "secret")).visibility == :private
    speak = Enum.find(dog.ops, &(&1.name == "speak"))
    assert speak.arity == 1

    # defstruct → fields with guessed types
    fields = MapSet.new(dog.fields, & &1.name)
    assert MapSet.equal?(fields, MapSet.new(["name", "age", "owner"]))

    # @callback module → interface
    assert by_ns["ElixirProj"].stereotype == :interface
    # defprotocol → interface
    assert by_ns["ElixirProj.Store.Special"].stereotype == :interface

    # edges: alias group {Store.Kennel, Store.Stock}, as:, behaviour, defimpl
    pairs =
      MapSet.new(scan.edges, fn edge ->
        {edge.from, edge.to, edge.kind}
      end)

    assert MapSet.member?(
             pairs,
             {"ElixirProj.Animals.Dog", "ElixirProj.Store.Kennel", :dependency}
           )

    assert MapSet.member?(
             pairs,
             {"ElixirProj.Animals.Dog", "ElixirProj.Store.Stock", :dependency}
           )

    assert MapSet.member?(
             pairs,
             {"ElixirProj.Animals.Dog", "ElixirProj.Store.Counter", :dependency}
           )

    assert MapSet.member?(
             pairs,
             {"ElixirProj.Animals.Dog", "ElixirProj.Animals.Cat", :dependency}
           )

    assert MapSet.member?(pairs, {"ElixirProj.Store.Stock", "ElixirProj", :implements})

    assert MapSet.member?(
             pairs,
             {"ElixirProj.Store.Special.BitString", "ElixirProj.Store.Special", :implements}
           )

    # use GenServer leaves the project → shows up as an unresolved ref (foreign later)
    assert Enum.any?(scan.edges, &(&1.from == "ElixirProj.Store.Kennel" and &1.to == "GenServer"))

    # alias-only ties count as dependencies
    assert MapSet.member?(
             pairs,
             {"ElixirProj.Store.Keeper", "ElixirProj.Animals.Cat", :dependency}
           )

    # defguard is an op; defdelegate is an op AND a dependency on its target
    keeper = by_ns["ElixirProj.Store.Keeper"]
    assert Enum.map(keeper.ops, & &1.name) == ["bump", "feed", "is_pet"]

    assert MapSet.member?(
             pairs,
             {"ElixirProj.Store.Keeper", "ElixirProj.Store.Counter", :dependency}
           )

    # macro-generated heads (def unquote(name)()) don't lose the whole file
    magic = by_ns["ElixirProj.MacroMagic"]
    assert magic
    assert Enum.any?(magic.ops, &(&1.name == "plain"))
  end

  test "resolves __MODULE__ at the head of an alias instead of crashing" do
    proj = Path.expand("../../fixtures/elixir_self_ref", __DIR__)
    {:ok, scan} = ElixirScanner.scan(proj, %{})

    assert scan.errors == []

    pairs = MapSet.new(scan.edges, &{&1.from, &1.to, &1.kind})

    for to <- [
          "SelfRef.Worker",
          "SelfRef.Cache",
          "SelfRef.Clock",
          "SelfRef.Registry",
          "SelfRef.Supervisor"
        ] do
      assert MapSet.member?(pairs, {"SelfRef", to, :dependency}), "missing SelfRef -> #{to}"
    end

    # `@attr.Child` can't be resolved statically: no edge, no crash
    refute Enum.any?(scan.edges, &String.contains?(&1.to, "Child"))

    ns = MapSet.new(scan.classes, & &1.ns)
    assert MapSet.member?(ns, "SelfRef.Inner")
    assert MapSet.member?(ns, "SelfRef.Inspect.SelfRef")
  end

  test "a stdlib name is not captured by a project module sharing its suffix" do
    proj = Path.expand("../../fixtures/elixir_self_ref", __DIR__)
    {:ok, scan} = ElixirScanner.scan(proj, %{})

    targets = for e <- scan.edges, e.from == "SelfRef.Server", into: MapSet.new(), do: e.to

    assert MapSet.member?(targets, "GenServer")
    refute MapSet.member?(targets, "SelfRef.Sync.GenServer")
  end

  test "errors on a non-directory" do
    assert {:error, {:not_a_directory, _}} = ElixirScanner.scan("/nope/does/not/exist", %{})
  end
end
