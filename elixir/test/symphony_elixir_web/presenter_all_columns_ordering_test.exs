defmodule SymphonyElixirWeb.PresenterAllColumnsOrderingTest do
  use ExUnit.Case, async: false

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

  setup do
    prev = Application.get_env(:symphony_elixir, :pr_status_fetcher)

    Application.put_env(
      :symphony_elixir,
      :pr_status_fetcher,
      fn _url -> {:ok, %{merged: true, review: nil}} end
    )

    on_exit(fn ->
      if prev do
        Application.put_env(:symphony_elixir, :pr_status_fetcher, prev)
      else
        Application.delete_env(:symphony_elixir, :pr_status_fetcher)
      end
    end)

    :ok
  end

  defp empty_orch do
    name = :"orch_all_cols_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Orch.start_link(
        name: name,
        snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
      )

    name
  end

  defp parse_dt(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    dt
  end

  defp base_issue(id, identifier, created_at_iso) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "t",
      url: "u",
      priority: 0,
      labels: [],
      blocked_by: [],
      repos: [],
      created_at: parse_dt(created_at_iso)
    }
  end

  defp todo_issue(id, identifier, iso),
    do: %{base_issue(id, identifier, iso) | state: "Backlog", state_type: "backlog"}

  defp in_progress_issue(id, identifier, iso),
    do: %{base_issue(id, identifier, iso) | state: "In Progress", state_type: "started"}

  defp in_review_issue(id, identifier, iso),
    do: %{base_issue(id, identifier, iso) | state: "Done", state_type: "completed"}

  defp done_issue(id, identifier, iso) do
    %{
      base_issue(id, identifier, iso)
      | state: "Done",
        state_type: "completed",
        repos: [%{name: "repo-#{id}", pr: %{url: "https://github.com/x/y/pull/#{id}", merged: true, review: nil}}]
    }
  end

  defp column_by(payload, key), do: Enum.find(payload.columns, &(&1.key == key))

  defp ids(column), do: Enum.map(column.issues, & &1.identifier)

  test "todo column sorts desc by created_at" do
    issues = [
      todo_issue("a", "T-1", "2026-01-01T00:00:00Z"),
      todo_issue("b", "T-2", "2026-04-30T00:00:00Z"),
      todo_issue("c", "T-3", "2026-03-01T00:00:00Z")
    ]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, empty_orch(), 1_000)
    assert ids(column_by(payload, "todo")) == ["T-2", "T-3", "T-1"]
  end

  test "in_progress column sorts desc by created_at" do
    issues = [
      in_progress_issue("a", "P-1", "2026-01-01T00:00:00Z"),
      in_progress_issue("b", "P-2", "2026-04-30T00:00:00Z"),
      in_progress_issue("c", "P-3", "2026-03-01T00:00:00Z")
    ]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, empty_orch(), 1_000)
    assert ids(column_by(payload, "in_progress")) == ["P-2", "P-3", "P-1"]
  end

  test "in_review column sorts desc by created_at" do
    issues = [
      in_review_issue("a", "R-1", "2026-01-01T00:00:00Z"),
      in_review_issue("b", "R-2", "2026-04-30T00:00:00Z"),
      in_review_issue("c", "R-3", "2026-03-01T00:00:00Z")
    ]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, empty_orch(), 1_000)
    assert ids(column_by(payload, "in_review")) == ["R-2", "R-3", "R-1"]
  end

  test "done column sorts desc by created_at" do
    issues = [
      done_issue("a", "D-1", "2026-01-01T00:00:00Z"),
      done_issue("b", "D-2", "2026-04-30T00:00:00Z"),
      done_issue("c", "D-3", "2026-03-01T00:00:00Z")
    ]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, empty_orch(), 1_000)
    assert ids(column_by(payload, "done")) == ["D-2", "D-3", "D-1"]
  end

  test "all four columns sort independently when issues are mixed" do
    issues = [
      todo_issue("t1", "T-1", "2026-01-01T00:00:00Z"),
      todo_issue("t2", "T-2", "2026-04-30T00:00:00Z"),
      in_progress_issue("p1", "P-1", "2026-02-01T00:00:00Z"),
      in_progress_issue("p2", "P-2", "2026-04-15T00:00:00Z"),
      in_review_issue("r1", "R-1", "2026-03-01T00:00:00Z"),
      in_review_issue("r2", "R-2", "2026-04-20T00:00:00Z"),
      done_issue("d1", "D-1", "2026-02-15T00:00:00Z"),
      done_issue("d2", "D-2", "2026-04-25T00:00:00Z")
    ]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, empty_orch(), 1_000)

    assert ids(column_by(payload, "todo")) == ["T-2", "T-1"]
    assert ids(column_by(payload, "in_progress")) == ["P-2", "P-1"]
    assert ids(column_by(payload, "in_review")) == ["R-2", "R-1"]
    assert ids(column_by(payload, "done")) == ["D-2", "D-1"]
  end
end
