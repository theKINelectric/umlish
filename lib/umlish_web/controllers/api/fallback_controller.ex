defmodule UmlishWeb.Api.FallbackController do
  @moduledoc """
  Last-resort JSON envelope for action returns the controllers don't
  handle themselves. Flow errors are already rescued in
  `Umlish.UmlRunner` and mapped by `SchemaResponse.flow_error/2`.
  """

  use UmlishWeb, :controller

  alias UmlishWeb.Api.SchemaResponse

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    SchemaResponse.error(conn, 422, "changeset: #{inspect(changeset_errors(changeset))}")
  end

  def call(conn, {:error, :not_found}) do
    SchemaResponse.error(conn, 404, "not found")
  end

  def call(conn, {:error, reason}) do
    SchemaResponse.error(conn, 422, inspect(reason))
  end

  def call(conn, other) do
    SchemaResponse.error(conn, 500, inspect(other))
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
