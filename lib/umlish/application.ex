defmodule Umlish.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      UmlishWeb.Telemetry,
      Umlish.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:umlish, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:umlish, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Umlish.PubSub},
      # Start a worker by calling: Umlish.Worker.start_link(arg)
      # {Umlish.Worker, arg},
      # Start to serve requests, typically the last entry
      UmlishWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Umlish.Supervisor]

    with {:ok, sup} <- Supervisor.start_link(children, opts) do
      # The UML generation flow — one FlowExtra pipeline shared by every
      # request, supervised by (and restarted with) this tree.
      Umlish.UmlRunner.start_under(sup)
      {:ok, sup}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UmlishWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end
end
