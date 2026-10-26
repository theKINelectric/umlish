defmodule Umlish.UmlPipelineTest do
  use ExUnit.Case, async: true

  alias Umlish.UmlPipeline

  @zig Path.expand("../fixtures/zig_proj", __DIR__)
  @elixir Path.expand("../fixtures/elixir_proj", __DIR__)

  # A private pipeline with persistence off — the shared one under the
  # app supervisor is exercised by the API tests.
  defp run_job(attrs) do
    pipeline = UmlPipeline.start(%{persist: false})

    try do
      UmlPipeline.call(pipeline, struct(UmlPipeline, attrs), 30_000)
    after
      UmlPipeline.stop(pipeline)
    end
  end

  test "a zig project flows through every stage" do
    job =
      run_job(
        kind: :project,
        path: @zig,
        scope: nil,
        started_at: System.monotonic_time(:millisecond)
      )

    assert job.errors == []
    assert job.snapshot_id == nil
    schema = job.schema

    assert schema.title =~ "Zig sources"
    packages = MapSet.new(schema.packages, & &1.id)
    assert MapSet.equal?(packages, MapSet.new(["core", "engine", "pets"]))

    root = Enum.find(schema.packages, &(&1.id == "core")).classes
    assert Enum.any?(root, &(&1.ns == "src/root.zig"))

    assert Enum.any?(schema.edges, &(&1.from == "src.root" and &1.to == "src.engine.tune"))

    std = Enum.find(schema.foreign, &(&1.id == "Std"))
    assert std
    assert schema.meta.foreign_refs["Std"] > 0
    assert schema.meta.class_count == 4
  end

  test "an elixir project flows through every stage" do
    job =
      run_job(
        kind: :project,
        path: @elixir,
        scope: nil,
        started_at: System.monotonic_time(:millisecond)
      )

    assert job.errors == []
    assert MapSet.new(job.schema.packages, & &1.id) == MapSet.new(["Animals", "Store", "core"])

    implements =
      Enum.filter(job.schema.edges, &(&1.kind == :implements))

    assert Enum.any?(implements, &(&1.to == "ElixirProj.Store.Special"))
  end

  test "bad input is captured, not raised" do
    job = run_job(kind: :project, path: "/nope/nothing/here", scope: nil)

    assert [message] = job.errors
    assert message =~ "not a readable directory"
    assert job.schema == nil
  end

  test "unknown project kinds are captured with a helpful message" do
    job = run_job(kind: :project, path: System.tmp_dir!(), scope: nil)

    assert [message] = job.errors
    assert message =~ "no scanner for"
  end
end
