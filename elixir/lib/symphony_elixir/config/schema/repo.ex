defmodule SymphonyElixir.Config.Schema.Repo do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:url, :string)
    field(:branch, :string, default: "main")
    field(:path, :string, default: ".")
    field(:install, :string)
    field(:verify, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:url, :branch, :path, :install, :verify], empty_values: [])
    |> validate_required([:url])
  end
end
