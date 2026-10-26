defmodule Umlish.Repo do
  use Ecto.Repo,
    otp_app: :umlish,
    adapter: Ecto.Adapters.SQLite3
end
