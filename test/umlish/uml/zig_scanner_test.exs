defmodule Umlish.Uml.ZigScannerTest do
  use ExUnit.Case, async: true

  alias Umlish.Uml.ZigScanner

  @proj Path.expand("../../fixtures/zig_proj", __DIR__)

  test "one class per file, pub fns as ops, @import as edges" do
    {:ok, scan} = ZigScanner.scan(@proj, %{})

    by_ns = Map.new(scan.classes, &{&1.ns, &1})

    assert MapSet.equal?(
             MapSet.new(Map.keys(by_ns)),
             MapSet.new([
               "src/root.zig",
               "src/main.zig",
               "src/engine/tune.zig",
               "src/pets/pet.zig"
             ])
           )

    # class names prettified from the basename
    root = by_ns["src/root.zig"]
    assert root.name == "Root"
    assert root.fields == [%Umlish.Uml.Schema.Field{name: "Config", type: "struct"}]

    # pub fn only — `hidden` stays private, `tune` is drawn
    tune = by_ns["src/engine/tune.zig"]
    assert Enum.map(tune.ops, & &1.name) == ["tune"]
    assert hd(tune.ops).args == ["input"]

    # edges: relative imports and the build.zig module import
    pairs = MapSet.new(scan.edges, &{&1.from, &1.to})

    assert MapSet.member?(pairs, {"src/root.zig", "src/engine/tune.zig"})
    assert MapSet.member?(pairs, {"src/pets/pet.zig", "src/root.zig"})
    assert MapSet.member?(pairs, {"src/main.zig", "src/pets/pet.zig"})

    # @import("std") is foreign: target "std" is not among the classes
    assert Enum.any?(scan.edges, &(&1.from == "src/main.zig" and &1.to == "std"))

    # prefixes run up to the src marker
    assert scan.prefixes == %{"src" => "core"}
  end

  test "scope :all walks the whole tree" do
    # A private copy — other tests scan @proj concurrently.
    dir =
      Path.join(
        System.tmp_dir!(),
        "uml_zig_scope_" <> Integer.to_string(:erlang.unique_integer([:positive]))
      )

    File.cp_r!(@proj, dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    File.mkdir_p!(Path.join(dir, "experiments"))

    File.write!(
      Path.join(dir, "experiments/try.zig"),
      "const std = @import(\"std\");\npub fn go() void {}\n"
    )

    {:ok, scan} = ZigScanner.scan(dir, %{scope: :all})
    assert Enum.any?(scan.classes, &(&1.ns == "experiments/try.zig"))

    {:ok, default} = ZigScanner.scan(dir, %{})
    refute Enum.any?(default.classes, &(&1.ns == "experiments/try.zig"))
  end

  test "errors on a non-directory" do
    assert {:error, {:not_a_directory, _}} = ZigScanner.scan("/nope/does/not/exist", %{})
  end
end
