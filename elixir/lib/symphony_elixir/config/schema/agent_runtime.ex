defmodule SymphonyElixir.Config.Schema.AgentRuntime do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema.AgentRuntime.Memoria
  alias SymphonyElixir.Config.Schema.StringOrMap

  @primary_key false
  embedded_schema do
    field(:provider, :string)
    field(:command, :string, default: "python -m symphony_agent_shim")

    field(:approval_policy, StringOrMap,
      default: %{
        "reject" => %{
          "sandbox_approval" => true,
          "rules" => true,
          "mcp_elicitations" => true
        }
      }
    )

    field(:docker_image, :string)
    field(:thread_sandbox, :string, default: "workspace-write")
    field(:turn_sandbox_policy, :map)
    field(:turn_timeout_ms, :integer, default: 3_600_000)
    field(:read_timeout_ms, :integer, default: 5_000)
    field(:stall_timeout_ms, :integer, default: 300_000)
    field(:tdd_phase_enforcement, :boolean, default: false)
    field(:bash_policy_allow, {:array, :string}, default: [])
    field(:branch_naming_pattern, :string)
    embeds_one(:memoria, Memoria, on_replace: :update)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(
      attrs,
      [
        :provider,
        :command,
        :docker_image,
        :approval_policy,
        :thread_sandbox,
        :turn_sandbox_policy,
        :turn_timeout_ms,
        :read_timeout_ms,
        :stall_timeout_ms,
        :tdd_phase_enforcement,
        :bash_policy_allow,
        :branch_naming_pattern
      ],
      empty_values: []
    )
    |> cast_embed(:memoria, with: &Memoria.changeset/2)
    |> validate_required([:command])
    |> validate_number(:turn_timeout_ms, greater_than: 0)
    |> validate_number(:read_timeout_ms, greater_than: 0)
    |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
  end
end
