defmodule Umlish.Uml.SchemaTest do
  use ExUnit.Case, async: true

  alias Umlish.Uml.Schema

  describe "classify/2" do
    test "groups by the first segment after the prefix" do
      prefixes = %{"UmlishWeb" => "Web", "Umlish" => "core"}

      assert {"Uml", ["ZigScanner", "Mermaid"]} =
               Schema.classify("Umlish.Uml.ZigScanner.Mermaid", prefixes)

      assert {"Uml", _} = Schema.classify("Umlish.Uml.Schema", prefixes)
    end

    test "single-segment remainders use the prefix fallback" do
      prefixes = %{"UmlishWeb" => "Web", "Umlish" => "core"}
      assert {"Web", ["Router"]} = Schema.classify("UmlishWeb.Router", prefixes)
      assert {"core", ["Repo"]} = Schema.classify("Umlish.Repo", prefixes)
      assert {"core", []} = Schema.classify("Umlish", prefixes)
    end

    test "the longest matching prefix wins" do
      prefixes = %{"apps.amrita.src" => "amrita", "src" => "core"}
      assert {"workbench", ["flow"]} = Schema.classify("src.workbench.flow", prefixes)
      assert {"amrita", ["tests"]} = Schema.classify("apps.amrita.src.tests", prefixes)
    end

    test "unprefixed ids take their first segment" do
      assert {"experiments", ["exp", "main"]} = Schema.classify("experiments.exp.main", %{})
    end
  end

  describe "group_packages/2" do
    test "groups classes preserving order and setting package ids" do
      class = fn ns -> %Schema.Class{ns: ns, id: ns, name: ns} end

      packages =
        Schema.group_packages(
          [class.("Umlish.Uml.ZigScanner"), class.("UmlishWeb.Router")],
          %{"UmlishWeb" => "Web", "Umlish" => "core"}
        )

      assert [%{id: "Uml"}, %{id: "Web"}] = packages

      assert [%Schema.Class{package_id: "Uml", id: "Umlish.Uml.ZigScanner"}] =
               hd(packages).classes
    end
  end

  describe "dedup_edges/1" do
    test "drops self edges and duplicates" do
      edges = [
        %Schema.Edge{from: "a", to: "a"},
        %Schema.Edge{from: "a", to: "b"},
        %Schema.Edge{from: "a", to: "b"}
      ]

      assert [%Schema.Edge{from: "a", to: "b"}] = Schema.dedup_edges(edges)
    end

    test "implements wins between the same pair" do
      edges = [
        %Schema.Edge{from: "a", to: "b", kind: :dependency},
        %Schema.Edge{from: "a", to: "b", kind: :implements}
      ]

      assert [%Schema.Edge{kind: :implements}] = Schema.dedup_edges(edges)
    end
  end

  describe "Mermaid.render/1" do
    test "namespaces, members, and arrows" do
      schema = %Schema{
        title: "t",
        packages: [
          %Schema.Package{
            id: "dom",
            label: "Dom",
            classes: [
              %Schema.Class{
                id: "dom.book",
                ns: "dom.book",
                name: "Book",
                stereotype: :interface,
                ops: [%Schema.Op{name: "find", args: ["isbn"], arity: 1}]
              },
              %Schema.Class{id: "dom.sql", ns: "dom.sql", name: "Sql"}
            ]
          }
        ],
        edges: [%Schema.Edge{from: "dom.sql", to: "dom.book", kind: :implements}],
        foreign: [%Schema.Class{id: "std", ns: "std", name: "Std"}]
      }

      out = Umlish.Uml.Mermaid.render(schema)

      assert out =~ "classDiagram"
      assert out =~ "direction TB"
      assert out =~ "namespace dom {"
      assert out =~ "namespace Foreign {"
      assert out =~ ~s(class c0["Book"])
      assert out =~ "c0 : +find(isbn)"
      assert out =~ "c0 : <<interface>>"
      assert out =~ "c1 ..|> c0"
    end
  end
end
