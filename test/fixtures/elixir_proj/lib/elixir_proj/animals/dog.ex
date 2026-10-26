defmodule ElixirProj.Animals.Dog do
  alias ElixirProj.Animals.Cat
  alias ElixirProj.{Store.Kennel, Store.Stock}
  alias ElixirProj.Store.Counter, as: Tally

  defstruct name: "rex", age: 3, owner: nil

  def speak(%__MODULE__{} = dog), do: dog.name <> " says woof"
  defp secret, do: :no

  def chase(%Cat{} = cat), do: Cat.run(cat)
  def nap(kennel), do: Kennel.book(kennel) |> Stock.hold() |> Tally.bump()
end
