defmodule ElixirProj.Store.Keeper do
  # alias-only module ties must still count as dependencies
  alias ElixirProj.Animals.Cat

  defguard is_pet(x) when is_atom(x)

  defdelegate bump(count), to: ElixirProj.Store.Counter

  def feed(%Cat{} = cat), do: cat
end
