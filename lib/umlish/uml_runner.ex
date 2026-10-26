defmodule Umlish.UmlRunner do
  @moduledoc """
  The request-facing door to the `Umlish.UmlPipeline` flow. The
  pipeline is started once under the application supervisor at boot and
  shared by every request (each call is one admitted Information
  Packet, bounded by FlowExtra's admission control).
  """

  alias Umlish.UmlPipeline

  @pipeline_key {Umlish.UmlPipeline, :default}
  @call_timeout 60_000

  @doc "Introspects this running service (`GET /api/internals`)."
  @spec run_internals() :: UmlPipeline.t() | {:error, term()}
  def run_internals do
    run(kind: :internals)
  end

  @doc "Scans a local project directory (`GET/POST /api/uml`)."
  @spec run_project(Path.t(), :all | nil) :: UmlPipeline.t() | {:error, term()}
  def run_project(path, scope \\ nil) when is_binary(path) do
    run(kind: :project, path: path, scope: scope)
  end

  # `call/3` raises on admission refusal or pipeline trouble (Phoenix's
  # action_fallback only sees returned values) — rescue here into tagged
  # tuples so the controllers can map them to 503/504/500.
  defp run(attrs) do
    pipeline = pipeline!()

    base = [
      job_id: :erlang.unique_integer([:positive]) |> Integer.to_string(),
      started_at: System.monotonic_time(:millisecond)
    ]

    job = struct(UmlPipeline, Keyword.merge(base, attrs))

    UmlPipeline.call(pipeline, job, @call_timeout)
  rescue
    error in FlowExtra.AdmissionError ->
      {:error, {:admission, error}}

    error in FlowExtra.PipelineError ->
      {:error, {:pipeline, error}}

    error ->
      # Pipeline not started, stale handle, anything else — still the
      # JSON envelope, never a bare Phoenix 500 page.
      {:error, {:unexpected, error}}
  end

  defp pipeline! do
    :persistent_term.get(@pipeline_key, nil) ||
      raise "UML pipeline not started — is the application supervision tree up?"
  end

  @doc "Starts the shared pipeline under `supervisor` (used by Application)."
  @spec start_under(pid()) :: :ok
  def start_under(supervisor) do
    pipeline = UmlPipeline.supervised_start(supervisor, %{admission_capacity: 50})
    :persistent_term.put(@pipeline_key, pipeline)
    :ok
  end
end
