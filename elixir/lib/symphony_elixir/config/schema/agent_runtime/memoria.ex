defmodule SymphonyElixir.Config.Schema.AgentRuntime.Memoria do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:project_id, :string)
    field(:project_tag, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:project_id, :project_tag])
    |> validate_required([:project_id, :project_tag])
  end
end
