defprotocol ElixirProj.Store.Special do
  @fallback_to_any true
  def special?(thing)
end

defimpl ElixirProj.Store.Special, for: BitString do
  def special?(_s), do: true
end
