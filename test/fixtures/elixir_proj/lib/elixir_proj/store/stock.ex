defmodule ElixirProj.Store.Stock do
  @behaviour ElixirProj

  def check(item), do: ElixirProj.validate(item)
end
