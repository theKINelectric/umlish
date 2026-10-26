defmodule UmlishWeb.GraphTest do
  use UmlishWeb.ConnCase, async: false

  # The persist stage runs inside a GenStage process, not the test
  # process — shared mode lets it see this test's sandboxed connection.
  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Umlish.Repo, {:shared, self()})
    :ok
  end

  @zig Path.expand("../fixtures/zig_proj", __DIR__)

  defp scan_zig(conn) do
    conn = get(conn, "/api/uml", path: @zig)
    %{"meta" => %{"snapshot_id" => id}} = json_response(conn, 200)
    id
  end

  describe "GET /api/schemas/:id/graph" do
    test "aggregates class edges into package pairs with evidence", %{conn: conn} do
      id = scan_zig(conn)
      conn = get(conn, "/api/schemas/" <> Integer.to_string(id) <> "/graph")

      assert %{"nodes" => nodes, "edges" => edges} = json = json_response(conn, 200)

      node_ids = Enum.map(nodes, & &1["id"])
      assert MapSet.equal?(MapSet.new(node_ids), MapSet.new(["core", "engine", "pets"]))

      core = Enum.find(nodes, &(&1["id"] == "core"))
      assert core["class_count"] == 2
      assert "src.root" in core["classes"]

      # root imports engine/tune; main imports pets/pet and root
      pair = Enum.find(edges, &(&1["from"] == "core" and &1["to"] == "engine"))
      assert pair["pair_count"] == 1

      [pair_edge] = pair["pairs"]
      assert pair_edge["from"] == "src.root"
      assert pair_edge["to"] == "src.engine.tune"
      assert [%{"file" => "src/root.zig", "line" => 2}] = pair_edge["evidence"]

      # foreign per package: std is leaned on from several components
      assert json["foreign"]["core"]["Std"] >= 1
    end

    test "as=mermaid renders a flowchart with click callbacks", %{conn: conn} do
      id = scan_zig(conn)
      conn = get(conn, "/api/schemas/" <> Integer.to_string(id) <> "/graph?as=mermaid")

      text = response(conn, 200)
      assert text =~ "flowchart TD"
      assert text =~ ~S{core["Core (2)"]}
      assert text =~ "core -->|"
      assert text =~ "engine"
      assert text =~ "click core umlPkgClick"
      assert text =~ "f_Std"
    end

    test "unknown snapshot is 404", %{conn: conn} do
      conn = get(conn, "/api/schemas/999999/graph")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/schemas/:id/graph/:package" do
    test "drills into one component", %{conn: conn} do
      id = scan_zig(conn)
      conn = get(conn, "/api/schemas/" <> Integer.to_string(id) <> "/graph/core")

      assert %{
               "node" => node,
               "classes" => classes,
               "outgoing" => outgoing,
               "incoming" => incoming
             } =
               json_response(conn, 200)

      assert node["id"] == "core"
      assert length(classes) == 2

      to_engine = Enum.find(outgoing, &(&1["to"] == "engine"))
      assert to_engine["pair_count"] == 1
      assert [%{"from" => "src.root", "to" => "src.engine.tune"} | _] = to_engine["pairs"]

      assert Enum.any?(incoming, &(&1["from"] == "pets"))
    end

    test "unknown package is 404", %{conn: conn} do
      id = scan_zig(conn)
      conn = get(conn, "/api/schemas/" <> Integer.to_string(id) <> "/graph/nope")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/schemas/:id/classes/:class_id" do
    test "class card carries both directions and evidence", %{conn: conn} do
      id = scan_zig(conn)
      conn = get(conn, "/api/schemas/" <> Integer.to_string(id) <> "/classes/src.root")

      assert %{"id" => "src.root", "ops" => ops, "outgoing" => outgoing, "incoming" => incoming} =
               json_response(conn, 200)

      assert Enum.map(ops, & &1["name"]) == ["launch"]

      dep = Enum.find(outgoing, &(&1["to"] == "src.engine.tune"))
      assert dep["kind"] == "dependency"
      assert [%{"file" => "src/root.zig", "line" => 2}] = dep["evidence"]

      assert Enum.any?(incoming, &(&1["from"] == "src.main"))
    end

    test "unknown class is 404", %{conn: conn} do
      id = scan_zig(conn)
      conn = get(conn, "/api/schemas/" <> Integer.to_string(id) <> "/classes/no.Such")
      assert json_response(conn, 404)
    end
  end

  describe "edge evidence in the document" do
    test "elixir edges carry the alias line", %{conn: conn} do
      conn = get(conn, "/api/uml", path: Path.expand("../fixtures/elixir_proj", __DIR__))
      %{"edges" => edges} = json_response(conn, 200)

      dog_to_cat =
        Enum.find(
          edges,
          &(&1["from"] == "ElixirProj.Animals.Dog" and &1["to"] == "ElixirProj.Animals.Cat")
        )

      assert dog_to_cat["evidence"] != []
      assert Enum.all?(dog_to_cat["evidence"], &(&1["file"] != nil))
    end
  end
end
