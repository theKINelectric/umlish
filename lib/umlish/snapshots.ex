defmodule Umlish.Snapshots do
  @moduledoc """
  The SQLite-backed snapshot store. Every generated schema is persisted
  by the pipeline's last stage; the API can list and replay them.
  """

  import Ecto.Query
  alias Umlish.Repo
  alias Umlish.Snapshots.UmlSnapshot

  @doc "Records a finished run. Never raises — persistence must not kill a good diagram."
  @spec record(map()) :: {:ok, UmlSnapshot.t()} | {:error, term()}
  def record(attrs) do
    changes =
      Map.take(attrs, [
        :kind,
        :title,
        :project_path,
        :language,
        :class_count,
        :package_count,
        :edge_count,
        :duration_ms,
        :document
      ])

    try do
      %UmlSnapshot{}
      |> Ecto.Changeset.change(changes)
      |> Repo.insert()
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  @doc "Newest first, without the (large) document column."
  @spec list() :: [map()]
  def list do
    from(s in UmlSnapshot,
      order_by: [desc: s.inserted_at, desc: s.id],
      limit: 100,
      select: %{
        id: s.id,
        kind: s.kind,
        title: s.title,
        project_path: s.project_path,
        language: s.language,
        class_count: s.class_count,
        package_count: s.package_count,
        edge_count: s.edge_count,
        duration_ms: s.duration_ms,
        inserted_at: s.inserted_at
      }
    )
    |> Repo.all()
  end

  @spec get(integer()) :: UmlSnapshot.t() | nil
  def get(id) do
    Repo.get(UmlSnapshot, id)
  end
end
