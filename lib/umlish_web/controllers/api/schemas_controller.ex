defmodule UmlishWeb.Api.SchemasController do
  @moduledoc """
  `GET /api/schemas` and `GET /api/schemas/:id` — the SQLite snapshot
  history: every document the flow has produced, replayable.
  """

  use UmlishWeb, :controller

  alias Umlish.Snapshots
  alias UmlishWeb.Api.SchemaResponse

  action_fallback UmlishWeb.Api.FallbackController

  def index(conn, _params) do
    snapshots =
      Snapshots.list()
      |> Enum.map(fn snapshot ->
        %{
          id: snapshot.id,
          kind: snapshot.kind,
          title: snapshot.title,
          project_path: snapshot.project_path,
          language: snapshot.language,
          class_count: snapshot.class_count,
          package_count: snapshot.package_count,
          edge_count: snapshot.edge_count,
          duration_ms: snapshot.duration_ms,
          inserted_at: snapshot.inserted_at
        }
      end)

    json(conn, %{data: snapshots})
  end

  def show(conn, %{"id" => id} = params) do
    case Integer.parse(id) do
      {int_id, ""} ->
        case Snapshots.get(int_id) do
          nil ->
            SchemaResponse.error(conn, 404, "no snapshot ##{int_id}")

          snapshot ->
            SchemaResponse.respond_document(conn, params, snapshot.document)
        end

      _ ->
        SchemaResponse.error(conn, 400, "invalid snapshot id: #{inspect(id)}")
    end
  end
end
