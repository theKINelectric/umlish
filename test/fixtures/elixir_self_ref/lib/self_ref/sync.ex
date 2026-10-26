# Fixture: a project module whose last segment shadows a stdlib name.
defmodule SelfRef.Sync.GenServer do
  def call(server, msg), do: {server, msg}
end

defmodule SelfRef.Server do
  use GenServer

  def init(state), do: {:ok, state}
  def ping(pid), do: GenServer.call(pid, :ping)
end
