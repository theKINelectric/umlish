# Fixture: `__MODULE__` and other expressions at the head of an alias.
# Not compiled; scanned as source only.
defmodule SelfRef do
  alias __MODULE__.Worker
  alias __MODULE__.{Cache, Clock}
  alias __MODULE__.Registry, as: Names

  def start(children) do
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end

  def touch, do: {Worker.run(), Cache.get(), Clock.now(), Names.lookup()}

  def dynamic(mod), do: @attr.Child.call(mod)

  defmodule __MODULE__.Inner do
    def ping, do: :pong
  end

  defimpl Inspect, for: __MODULE__ do
    def inspect(_, _), do: "#SelfRef<>"
  end
end

defmodule SelfRef.Worker do
  def run, do: :ok
end
