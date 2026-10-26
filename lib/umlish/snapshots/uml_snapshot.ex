defmodule Umlish.Snapshots.UmlSnapshot do
  @moduledoc """
  One persisted UML document — the SQLite record of a generation run
  (from `/api/internals` or `/api/uml`), stored verbatim as JSON so any
  snapshot can be re-rendered later.
  """

  use Ecto.Schema

  schema "uml_snapshots" do
    field :kind, :string
    field :title, :string
    field :project_path, :string
    field :language, :string
    field :class_count, :integer, default: 0
    field :package_count, :integer, default: 0
    field :edge_count, :integer, default: 0
    field :duration_ms, :integer, default: 0
    field :document, :map
    timestamps(type: :utc_datetime)
  end
end
