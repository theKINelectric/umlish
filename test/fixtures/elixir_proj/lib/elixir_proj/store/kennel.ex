defmodule ElixirProj.Store.Kennel do
  use GenServer

  def book(kennel), do: {:ok, kennel}
  def hold(_), do: :held
end
