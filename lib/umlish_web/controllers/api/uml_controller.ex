defmodule UmlishWeb.Api.UmlController do
  @moduledoc """
  `GET /api/uml?path=DIR` and `POST /api/uml {"path": DIR}` — the
  project endpoint. Takes a local project directory (Elixir with a
  `mix.exs`, Zig with a `build.zig`) and answers with its UML schema.
  """

  use UmlishWeb, :controller

  alias Umlish.UmlPipeline
  alias Umlish.UmlRunner
  alias UmlishWeb.Api.SchemaResponse

  action_fallback UmlishWeb.Api.FallbackController

  def create(conn, params) do
    path = params["path"]

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        SchemaResponse.error(
          conn,
          400,
          "missing \"path\": pass ?path=/path/to/project or {\"path\": \"/path/to/project\"}"
        )

      true ->
        scope = if params["scope"] == "all", do: :all, else: nil

        case UmlRunner.run_project(path, scope) do
          %UmlPipeline{} = job -> SchemaResponse.respond(conn, params, job)
          {:error, reason} -> SchemaResponse.flow_error(conn, reason)
        end
    end
  end
end
