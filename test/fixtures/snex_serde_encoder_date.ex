defimpl Snex.Serde.Encoder, for: Date do
  @impl Snex.Serde.Encoder
  def encode(%Date{} = d),
    do: Snex.Serde.object("datetime", "date", [d.year, d.month, d.day])
end
