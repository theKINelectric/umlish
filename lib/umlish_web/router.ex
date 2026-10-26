defmodule UmlishWeb.Router do
  use UmlishWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {UmlishWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", UmlishWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # The UML schema service.
  #
  #   GET  /api/internals          — UML of this running service (live
  #                                  BEAM introspection through the flow)
  #   GET  /api/uml?path=DIR       — UML of a local project directory
  #   POST /api/uml  {"path":DIR}  — same, JSON body
  #   GET  /api/schemas            — persisted snapshots (SQLite)
  #   GET  /api/schemas/:id        — replay one snapshot
  #
  # Every document endpoint also answers `?as=mermaid` with a
  # Mermaid classDiagram rendering of the same schema.
  scope "/api", UmlishWeb.Api, as: :api do
    pipe_through :api

    get "/internals", InternalsController, :show
    get "/uml", UmlController, :create
    post "/uml", UmlController, :create
    get "/schemas", SchemasController, :index
    get "/schemas/:id", SchemasController, :show

    # Drill-down (package graph with dependency evidence), derived from
    # stored snapshots:
    #   /api/schemas/:id/graph[?as=mermaid]  — component graph
    #   /api/schemas/:id/graph/:package      — component detail
    #   /api/schemas/:id/classes/:class_id   — class card with evidence
    get "/schemas/:id/graph", GraphController, :show
    get "/schemas/:id/graph/:package", GraphController, :package
    get "/schemas/:id/classes/:class_id", GraphController, :clazz
  end
end
