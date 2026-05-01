defmodule SymphonyElixirWeb.PresenterOrderingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.Presenter

  defmodule Orch do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end
  end

  defp empty_orch do
    name = :"orch_ord_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Orch.start_link(
        name: name,
        snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
      )

    name
  end

  defp issue(id, identifier, created_at_iso) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "t",
      url: "u",
      state: "Backlog",
      state_type: "backlog",
      priority: 0,
      labels: [],
      blocked_by: [],
      repos: [],
      created_at: parse_dt(created_at_iso)
    }
  end

  defp parse_dt(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  defp todo_column(payload), do: Enum.find(payload.columns, &(&1.key == "todo"))

  test "issues within a column are sorted desc by created_at (newest first)" do
    older = issue("a", "MOM-1", "2026-01-01T00:00:00Z")
    newer = issue("b", "MOM-2", "2026-04-30T00:00:00Z")
    middle = issue("c", "MOM-3", "2026-03-01T00:00:00Z")

    payload =
      Presenter.board_payload(fn -> {:ok, [older, newer, middle]} end, empty_orch(), 1_000)

    column = todo_column(payload)

    assert Enum.map(column.issues, & &1.identifier) == ["MOM-2", "MOM-3", "MOM-1"]
  end

  test "issues with nil created_at sink to the bottom of the column" do
    no_date = %{issue("a", "MOM-1", "2026-01-01T00:00:00Z") | created_at: nil}
    dated = issue("b", "MOM-2", "2026-04-30T00:00:00Z")

    payload = Presenter.board_payload(fn -> {:ok, [no_date, dated]} end, empty_orch(), 1_000)
    column = todo_column(payload)

    assert Enum.map(column.issues, & &1.identifier) == ["MOM-2", "MOM-1"]
  end
end
