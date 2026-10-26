defmodule ElixirProj.MacroMagic do
  defmacro defpet(name) do
    quote do
      def unquote(name)(), do: :ok
    end
  end

  def plain(), do: :ok
end
