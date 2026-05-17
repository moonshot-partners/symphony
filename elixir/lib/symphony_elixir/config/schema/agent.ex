defmodule SymphonyElixir.Config.Schema.Agent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema

  @primary_key false
  embedded_schema do
    field(:max_concurrent_agents, :integer, default: 10)
    field(:max_turns, :integer, default: 20)
    field(:max_retry_backoff_ms, :integer, default: 300_000)
    field(:max_retries, :integer, default: 5)
    field(:max_concurrent_agents_by_state, :map, default: %{})
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :max_concurrent_agents,
        :max_turns,
        :max_retry_backoff_ms,
        :max_retries,
        :max_concurrent_agents_by_state
      ],
      empty_values: []
    )
    |> validate_number(:max_concurrent_agents, greater_than: 0)
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:max_retry_backoff_ms, greater_than: 0)
    |> validate_number(:max_retries, greater_than: 0)
    |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
    |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
  end
end
