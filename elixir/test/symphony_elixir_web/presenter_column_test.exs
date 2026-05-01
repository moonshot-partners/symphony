defmodule SymphonyElixirWeb.PresenterColumnTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.Presenter

  defmodule Orch do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end
  end

  defp empty_orch do
    name = :"orch_col_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Orch.start_link(
        name: name,
        snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
      )

    name
  end

  defp board(issues) do
    Presenter.board_payload(fn -> {:ok, issues} end, empty_orch(), 1_000)
  end

  defp issue(attrs) do
    Map.merge(
      %Issue{
        id: "i1",
        identifier: "SODEV-1",
        title: "t",
        url: "u",
        state: "Backlog",
        state_type: "backlog",
        priority: 0,
        labels: [],
        blocked_by: [],
        repos: []
      },
      Map.new(attrs)
    )
  end

  defp issue_in_column(payload, key, identifier) do
    column = Enum.find(payload.columns, &(&1.key == key))
    column && Enum.any?(column.issues, &(&1.identifier == identifier))
  end

  test "board exposes 4 columns: todo, in_progress, in_review, done" do
    payload = board([])
    assert Enum.map(payload.columns, & &1.key) == ["todo", "in_progress", "in_review", "done"]
  end

  test "started + open PR routes issue to in_review" do
    i =
      issue(%{
        state_type: "started",
        repos: [%{name: "symphony", pr: %{url: "u", merged: false, review: nil}}]
      })

    assert issue_in_column(board([i]), "in_review", "SODEV-1")
  end

  test "completed + all PRs merged routes to done" do
    i =
      issue(%{
        state_type: "completed",
        repos: [%{name: "s", pr: %{url: "u", merged: true, review: nil}}]
      })

    assert issue_in_column(board([i]), "done", "SODEV-1")
  end

  test "completed + open PR keeps issue in in_review" do
    i =
      issue(%{
        state_type: "completed",
        repos: [%{name: "s", pr: %{url: "u", merged: false, review: nil}}]
      })

    assert issue_in_column(board([i]), "in_review", "SODEV-1")
  end

  test "started without PR stays in_progress" do
    i = issue(%{state_type: "started", repos: []})
    assert issue_in_column(board([i]), "in_progress", "SODEV-1")
  end

  test "backlog/unstarted/triage all map to todo" do
    for t <- ["backlog", "unstarted", "triage"] do
      i = issue(%{identifier: "I-#{t}", state_type: t})
      assert issue_in_column(board([i]), "todo", "I-#{t}"), "expected #{t} -> todo"
    end
  end

  test "canceled issues are filtered out" do
    i = issue(%{state_type: "canceled"})
    payload = board([i])
    refute Enum.any?(payload.columns, fn c -> Enum.any?(c.issues, &(&1.identifier == "SODEV-1")) end)
  end

  test "payload exposes repos, column, state_type, blocked_by, created_at; drops pr_url" do
    {:ok, created_at, _} = DateTime.from_iso8601("2026-04-30T19:00:00Z")

    i =
      issue(%{
        state_type: "started",
        repos: [%{name: "s", pr: %{url: "u", merged: false, review: nil}}],
        blocked_by: ["SODEV-2"],
        created_at: created_at
      })

    [card | _] = Enum.flat_map(board([i]).columns, & &1.issues)

    assert card.column == "in_review"
    assert card.state_type == "started"
    assert card.repos == [%{name: "s", pr: %{url: "u", merged: false, review: nil}}]
    assert card.blocked_by == ["SODEV-2"]
    assert card.created_at == "2026-04-30T19:00:00Z"
    refute Map.has_key?(card, :pr_url)
  end
end
