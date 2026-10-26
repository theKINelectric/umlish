defmodule Umlish.Repo.Migrations.CreateUmlSnapshots do
  use Ecto.Migration

  def change do
    create table(:uml_snapshots) do
      add :kind, :string, null: false
      add :title, :string, null: false
      add :project_path, :string
      add :language, :string
      add :class_count, :integer, default: 0, null: false
      add :package_count, :integer, default: 0, null: false
      add :edge_count, :integer, default: 0, null: false
      add :duration_ms, :integer, default: 0, null: false
      add :document, :map, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:uml_snapshots, [:inserted_at])
  end
end
