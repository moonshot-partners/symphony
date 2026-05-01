defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :assignee_name,
    :assignee_display_name,
    blocked_by: [],
    labels: [],
    repos: [],
    state_type: nil,
    column: nil,
    assigned_to_worker: true,
    has_pr_attachment: false,
    created_at: nil,
    updated_at: nil
  ]

  @type repo :: %{
          required(:name) => String.t(),
          required(:pr) => nil | %{required(:url) => String.t(), optional(atom()) => any()}
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          assignee_name: String.t() | nil,
          assignee_display_name: String.t() | nil,
          labels: [String.t()],
          repos: [repo()],
          state_type: String.t() | nil,
          column: String.t() | nil,
          assigned_to_worker: boolean(),
          has_pr_attachment: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
