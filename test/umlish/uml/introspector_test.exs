defmodule Umlish.Uml.IntrospectorTest do
  use ExUnit.Case, async: true

  alias Umlish.Uml.Introspector

  test "introspects this running test application" do
    {:ok, scan} = Introspector.scan(nil, %{})

    by_ns = Map.new(scan.classes, &{&1.ns, &1})

    # our own modules are on the diagram with their public functions
    scanner = by_ns["Umlish.Uml.ZigScanner"]
    assert scanner
    assert Enum.any?(scanner.ops, &(&1.name == "scan" and &1.arity == 2))
    assert scanner.lang == :beam

    # the pipeline struct module's struct becomes fields
    pipeline = by_ns["Umlish.UmlPipeline"]
    assert %Umlish.Uml.Schema.Class{} = pipeline
    assert Enum.any?(pipeline.fields, &(&1.name == "kind"))

    # calls compiled into our beams become edges
    assert Enum.any?(
             scan.edges,
             &(&1.from == "Umlish.UmlRunner" and &1.to == "Umlish.UmlPipeline" and
                 &1.kind == :dependency)
           )

    # Phoenix is foreign, never a project class
    assert Enum.any?(scan.edges, &(&1.to =~ "Phoenix"))
    refute Map.has_key?(by_ns, "Phoenix")
  end
end
