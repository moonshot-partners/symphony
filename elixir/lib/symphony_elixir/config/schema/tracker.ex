defmodule SymphonyElixir.Config.Schema.Tracker do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field(:kind, :string)
    field(:endpoint, :string, default: "https://api.linear.app/graphql")
    field(:api_key, :string)
    field(:project_slug, :string)
    field(:team_key, :string)
    field(:assignee, :string)
    field(:routing_label, :string)
    field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
    field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    field(:on_pickup_state, :string)
    field(:on_complete_state, :string)
    field(:on_pr_merge_state, :string)
    field(:on_reject_state, :string)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :kind,
        :endpoint,
        :api_key,
        :project_slug,
        :team_key,
        :assignee,
        :routing_label,
        :active_states,
        :terminal_states,
        :on_pickup_state,
        :on_complete_state,
        :on_pr_merge_state,
        :on_reject_state
      ],
      empty_values: []
    )
  end
end
