defmodule SymphonyElixir.Config.Schema.Cockpit do
  @moduledoc """
  Cockpit board display config. Decoupled from the agent's dispatch/lifecycle
  config (`tracker.active_states` / `terminal_states`): the agent only dispatches
  from its active states, but the board can SHOW more of the team workflow.

  - `up_next_states`: extra states that belong in the "Up next" column beyond the
    tracker's active states (e.g. Backlog, Groomed) — shown, never dispatched.
  - `done_states`: extra states that belong in the "Done" column beyond the
    tracker's terminal states (e.g. Approved QA, Recently released) — shown as
    finished even though they are not terminal for the agent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:up_next_states, {:array, :string}, default: [])
    field(:done_states, {:array, :string}, default: [])
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    cast(schema, attrs, [:up_next_states, :done_states], empty_values: [])
  end
end
