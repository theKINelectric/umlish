defmodule ElixirProj.Animals.Cat do
  defstruct [:name]

  def run(_cat), do: :fast
  defp purr, do: :quiet
end
