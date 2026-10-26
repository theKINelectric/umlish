defmodule UmlishWeb.Api.GraphController do
  @moduledoc """
  The drill-down endpoints (Codex's recommended increment). Everything
  derives from a stored snapshot, so any past run — live internals or a
  project scan — can be explored:

      GET /api/schemas/:id/graph                — package graph
      GET /api/schemas/:id/graph?as=mermaid     — flowchart whose nodes
                                                  call back (umlPkgClick)
      GET /api/schemas/:id/graph/:package       — one component: classes,
                                                  in/out edges with pairs
      GET /api/schemas/:id/classes/:class_id    — one class card: ops,
                                                  fields, in/out deps with
                                                  file:line evidence
  """

  use UmlishWeb, :controller

  alias Umlish.Snapshots
  alias Umlish.Uml.PackageGraph
  alias UmlishWeb.Api.SchemaResponse

  action_fallback UmlishWeb.Api.FallbackController

  def show(conn, %{"id" => id} = params) do
    case fetch_snapshot(conn, id) do
      {:ok, snapshot} ->
        graph = PackageGraph.build(snapshot.document)

        if params["as"] == "mermaid" do
          conn
          |> put_resp_content_type("text/plain")
          |> send_resp(200, PackageGraph.mermaid(graph))
        else
          json(conn, graph)
        end

      {:error, conn} ->
        conn
    end
  end

  def package(conn, %{"id" => id, "package" => package_id}) do
    case fetch_snapshot(conn, id) do
      {:ok, snapshot} ->
        case PackageGraph.package(snapshot.document, package_id) do
          nil ->
            SchemaResponse.error(
              conn,
              404,
              "no package #{inspect(package_id)} in snapshot ##{id}"
            )

          detail ->
            meta = %{
              "snapshot_id" => snapshot.id,
              "document_title" => snapshot.title
            }

            json(conn, Map.put(detail, :meta, meta))
        end

      {:error, conn} ->
        conn
    end
  end

  def clazz(conn, %{"id" => id, "class_id" => class_id}) do
    case fetch_snapshot(conn, id) do
      {:ok, snapshot} ->
        case PackageGraph.clazz(snapshot.document, class_id) do
          nil ->
            SchemaResponse.error(conn, 404, "no class #{inspect(class_id)} in snapshot ##{id}")

          detail ->
            json(conn, Map.put(detail, "meta", %{"snapshot_id" => snapshot.id}))
        end

      {:error, conn} ->
        conn
    end
  end

  # Sends the error response and returns the conn so the caller can
  # return it directly (action_fallback only sees value returns).
  defp fetch_snapshot(conn, id) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case Snapshots.get(int_id) do
          nil -> {:error, SchemaResponse.error(conn, 404, "no snapshot ##{int_id}")}
          snapshot -> {:ok, snapshot}
        end

      _ ->
        {:error, SchemaResponse.error(conn, 400, "invalid snapshot id: #{inspect(id)}")}
    end
  end
end
