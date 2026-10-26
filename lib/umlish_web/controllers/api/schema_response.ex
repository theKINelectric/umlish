defmodule UmlishWeb.Api.SchemaResponse do
  @moduledoc """
  Shared responder for the schema endpoints: JSON document by default,
  `?as=mermaid` for a Mermaid classDiagram, and a uniform error
  envelope mapped from the pipeline's captured errors.
  """

  alias Umlish.Uml
  alias Umlish.UmlPipeline

  import Plug.Conn

  @doc "Renders a finished pipeline job (`?as=mermaid` supported)."
  @spec respond(Plug.Conn.t(), map(), UmlPipeline.t()) :: Plug.Conn.t()
  def respond(conn, params, job) do
    cond do
      job.errors != [] ->
        error(conn, classify(hd(job.errors)), hd(job.errors))

      params["as"] == "mermaid" ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, Uml.Mermaid.render(job.schema))

      true ->
        conn
        |> put_status(200)
        |> Phoenix.Controller.json(document(job))
    end
  end

  # Caller mistakes (bad path, unknown project kind) are 422; anything
  # the flow caught deeper is ours — 500.
  defp classify(message) when is_binary(message) do
    if String.starts_with?(message, "not a readable directory") or
         String.starts_with?(message, "no scanner for") or
         String.starts_with?(message, "scan failed:") or
         String.starts_with?(message, "expected kind"),
       do: 422,
       else: 500
  end

  defp classify(_), do: 500

  @doc "Renders a stored snapshot document (`?as=mermaid` supported)."
  @spec respond_document(Plug.Conn.t(), map(), map()) :: Plug.Conn.t()
  def respond_document(conn, params, document) do
    if params["as"] == "mermaid" do
      schema = document_to_schema(document)

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, Uml.Mermaid.render(schema))
    else
      conn
      |> put_status(200)
      |> Phoenix.Controller.json(document)
    end
  end

  @doc "The JSON body: the document with the run's bookkeeping folded into `meta`."
  @spec document(UmlPipeline.t()) :: map()
  def document(job) do
    meta =
      job.schema.meta
      |> Map.put("snapshot_id", job.snapshot_id)
      |> Map.put("job_id", job.job_id)
      |> Map.put("notes", job.notes)

    %{job.schema | meta: meta} |> Uml.Json.to_map()
  end

  @doc """
  Maps rescued FlowExtra failures (codex review: definite overload → 503
  with Retry-After, expired budget → 504, anything else → 500). FlowExtra
  distinguishes definite refusal from `:unacknowledged` — that uncertainty
  is preserved in the message, since the snapshot may or may not exist.
  """
  @spec flow_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def flow_error(conn, {:admission, error}) do
    conn
    |> put_resp_header("retry-after", "1")
    |> error(503, "flow refused the work: " <> Exception.message(error))
  end

  def flow_error(conn, {:pipeline, %FlowExtra.PipelineError{reason: :timeout} = error}) do
    error(conn, 504, "flow budget expired: " <> Exception.message(error))
  end

  def flow_error(conn, {:pipeline, error}) do
    error(conn, 500, "flow failed: " <> Exception.message(error))
  end

  def flow_error(conn, other), do: error(conn, 500, inspect(other))

  @spec error(Plug.Conn.t(), integer(), String.t()) :: Plug.Conn.t()
  def error(conn, status, message) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: %{status: status, message: message}})
  end

  defp document_to_schema(document) do
    alias Umlish.Uml.Schema

    packages =
      Enum.map(document["packages"] || [], fn pkg ->
        %Schema.Package{
          id: pkg["id"],
          label: pkg["label"],
          classes: Enum.map(pkg["classes"] || [], &class_from_json/1)
        }
      end)

    foreign = Enum.map(document["foreign"] || [], &class_from_json/1)

    edges =
      Enum.map(document["edges"] || [], fn edge ->
        %Schema.Edge{
          from: edge["from"],
          to: edge["to"],
          kind: safe_atom(edge["kind"], :dependency),
          label: edge["label"]
        }
      end)

    %Schema{
      title: document["title"],
      direction: safe_atom(document["direction"], :tb),
      packages: packages,
      edges: edges,
      foreign: foreign
    }
  end

  defp safe_atom(value, default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> default
  end

  defp safe_atom(_, default), do: default

  defp class_from_json(json) do
    alias Umlish.Uml.Schema

    %Schema.Class{
      id: json["id"],
      name: json["name"],
      ns: json["ns"],
      stereotype: json["stereotype"] && safe_atom(json["stereotype"], :class),
      lang: json["lang"] && safe_atom(json["lang"], :unknown),
      file: json["file"],
      fields: Enum.map(json["fields"] || [], &%Schema.Field{name: &1["name"], type: &1["type"]}),
      ops:
        Enum.map(json["ops"] || [], fn op ->
          %Schema.Op{
            name: op["name"],
            args: op["args"],
            arity: op["arity"],
            visibility: safe_atom(op["visibility"] || "public", :public)
          }
        end)
    }
  end
end
