defmodule UmlishWeb.ApiTest do
  use UmlishWeb.ConnCase, async: false

  # The persist stage runs inside a GenStage process, not the test
  # process — shared mode lets it see this test's sandboxed connection.
  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Umlish.Repo, {:shared, self()})
    :ok
  end

  @zig Path.expand("../fixtures/zig_proj", __DIR__)

  describe "GET /api/internals" do
    test "returns the live schema document and persists a snapshot", %{conn: conn} do
      conn = get(conn, "/api/internals")

      assert %{"title" => title, "meta" => meta} = json_response(conn, 200)
      assert title =~ "live"
      assert meta["kind"] == "internals"
      assert meta["language"] == "beam"
      assert meta["class_count"] > 10
      assert meta["snapshot_id"] > 0

      packages = Enum.map(json_response(conn, 200)["packages"], & &1["id"])
      assert "Web" in packages
      assert "Uml" in packages
    end

    test "as=mermaid renders a class diagram", %{conn: conn} do
      conn = get(conn, "/api/internals?as=mermaid")

      assert response_content_type(conn, :text)
      assert response(conn, 200) =~ "classDiagram"
    end
  end

  describe "GET /api/uml" do
    test "scans a local project directory", %{conn: conn} do
      conn = get(conn, "/api/uml", path: @zig)

      assert %{"title" => title, "meta" => meta} = json_response(conn, 200)
      assert title =~ "Zig sources"
      assert meta["kind"] == "project"
      assert meta["language"] == "zig"
      assert meta["class_count"] == 4
    end

    test "scope=all walks the whole tree", %{conn: conn} do
      conn = get(conn, "/api/uml", path: @zig, scope: "all")
      # 4 src files + build.zig itself, which only :all reaches
      assert json_response(conn, 200)["meta"]["class_count"] == 5
    end

    test "missing path is a 400", %{conn: conn} do
      conn = get(conn, "/api/uml")
      assert %{"error" => %{"status" => 400}} = json_response(conn, 400)
    end

    test "bad path is a 422 with a helpful message", %{conn: conn} do
      conn = get(conn, "/api/uml", path: "/nope/nowhere")
      assert %{"error" => %{"status" => 422, "message" => message}} = json_response(conn, 422)
      assert message =~ "not a readable directory"
    end
  end

  describe "POST /api/uml" do
    test "accepts a JSON body", %{conn: conn} do
      conn = post(conn, "/api/uml", %{"path" => @zig})
      assert json_response(conn, 200)["meta"]["language"] == "zig"
    end
  end

  describe "snapshots" do
    test "list and replay", %{conn: conn} do
      get(conn, "/api/internals")
      list = get(conn, "/api/schemas")
      assert %{"data" => [newest | _]} = json_response(list, 200)
      assert newest["kind"] == "internals"
      assert is_integer(newest["class_count"])

      replay = get(conn, "/api/schemas/" <> Integer.to_string(newest["id"]))
      assert %{"meta" => replay_meta, "edges" => edges} = json_response(replay, 200)
      assert replay_meta["class_count"] == newest["class_count"]
      assert edges != []

      missing = get(conn, "/api/schemas/999999")
      assert json_response(missing, 404)
    end

    test "mermaid replay keeps relationships", %{conn: conn} do
      get(conn, "/api/uml", path: @zig)
      list = get(conn, "/api/schemas")
      %{"data" => [newest | _]} = json_response(list, 200)

      replay = get(conn, "/api/schemas/" <> Integer.to_string(newest["id"]) <> "?as=mermaid")
      assert response(replay, 200) =~ "-->"
    end

    test "non-string path is a 400", %{conn: conn} do
      conn = get(conn, "/api/uml", path: %{oops: true})
      assert %{"error" => %{"status" => 400}} = json_response(conn, 400)
    end
  end
end
