defmodule ElixirProj do
  @callback validate(term()) :: :ok | {:error, term()}

  def validate(value) when is_binary(value), do: :ok
  def validate(_), do: {:error, :bad_type}
end
