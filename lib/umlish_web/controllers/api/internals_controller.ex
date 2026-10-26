defmodule UmlishWeb.Api.InternalsController do
  @moduledoc """
  `GET /api/internals` — the introspective endpoint. Every request
  re-runs the flow against the *running* node: modules actually loaded
  right now, calls actually compiled into those beams.
  """

  use UmlishWeb, :controller

  alias Umlish.UmlPipeline
  alias Umlish.UmlRunner
  alias UmlishWeb.Api.SchemaResponse

  action_fallback UmlishWeb.Api.FallbackController

  def show(conn, params) do
    case UmlRunner.run_internals() do
      %UmlPipeline{} = job -> SchemaResponse.respond(conn, params, job)
      {:error, reason} -> SchemaResponse.flow_error(conn, reason)
    end
  end
end
