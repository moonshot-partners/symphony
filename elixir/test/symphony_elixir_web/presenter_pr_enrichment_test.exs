defmodule SymphonyElixirWeb.PresenterPrEnrichmentTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.Presenter

  defmodule Orch do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    def init(opts), do: {:ok, opts}
    def handle_call(:snapshot, _from, state), do: {:reply, Keyword.fetch!(state, :snapshot), state}
  end

  setup do
    prev = Application.get_env(:symphony_elixir, :pr_status_fetcher)

    on_exit(fn ->
      if prev do
        Application.put_env(:symphony_elixir, :pr_status_fetcher, prev)
      else
        Application.delete_env(:symphony_elixir, :pr_status_fetcher)
      end
    end)

    :ok
  end

  defp orch_name do
    name = :"orch_pr_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Orch.start_link(
        name: name,
        snapshot: %{running: [], retrying: [], agent_totals: %{}, rate_limits: nil}
      )

    name
  end

  defp issue(repos) do
    %Issue{
      id: "i1",
      identifier: "SODEV-1",
      title: "t",
      url: "u",
      state: "In Review",
      state_type: "started",
      labels: [],
      blocked_by: [],
      repos: repos
    }
  end

  test "board_payload enriches each repo PR via the configured fetcher" do
    Application.put_env(
      :symphony_elixir,
      :pr_status_fetcher,
      fn url ->
        cond do
          String.ends_with?(url, "/pull/1") -> {:ok, %{merged: true, review: nil}}
          String.ends_with?(url, "/pull/2") -> {:ok, %{merged: false, review: "draft"}}
        end
      end
    )

    issues = [
      issue([
        %{name: "a", pr: %{url: "https://github.com/me/a/pull/1", merged: false, review: nil}},
        %{name: "b", pr: %{url: "https://github.com/me/b/pull/2", merged: false, review: nil}}
      ])
    ]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, orch_name(), 1_000)

    [card | _] = Enum.flat_map(payload.columns, & &1.issues)
    assert [%{pr: %{merged: true, review: nil}}, %{pr: %{merged: false, review: "draft"}}] = card.repos
  end

  test "board_payload keeps original repo when fetcher errors" do
    Application.put_env(
      :symphony_elixir,
      :pr_status_fetcher,
      fn _url -> {:error, :boom} end
    )

    pr = %{url: "https://github.com/me/a/pull/1", merged: false, review: nil}
    issues = [issue([%{name: "a", pr: pr}])]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, orch_name(), 1_000)
    [card | _] = Enum.flat_map(payload.columns, & &1.issues)
    assert card.repos == [%{name: "a", pr: pr}]
  end

  test "board_payload enriches PRs in parallel" do
    Application.put_env(
      :symphony_elixir,
      :pr_status_fetcher,
      fn _url ->
        Process.sleep(50)
        {:ok, %{merged: false, review: nil}}
      end
    )

    issues =
      for i <- 1..8 do
        %{
          issue([
            %{
              name: "r#{i}",
              pr: %{
                url: "https://github.com/me/r#{i}/pull/1",
                merged: false,
                review: nil
              }
            }
          ])
          | id: "i#{i}",
            identifier: "SODEV-#{i}"
        }
      end

    {elapsed_us, payload} =
      :timer.tc(fn ->
        Presenter.board_payload(fn -> {:ok, issues} end, orch_name(), 1_000)
      end)

    cards = Enum.flat_map(payload.columns, & &1.issues)
    assert length(cards) == 8
    assert div(elapsed_us, 1_000) < 200,
           "expected parallel enrichment under 200ms, got #{div(elapsed_us, 1_000)}ms"
  end

  test "board_payload completed+all_merged routes to done after enrichment" do
    Application.put_env(
      :symphony_elixir,
      :pr_status_fetcher,
      fn _url -> {:ok, %{merged: true, review: nil}} end
    )

    issues = [
      %{
        issue([%{name: "a", pr: %{url: "https://github.com/me/a/pull/1", merged: false, review: nil}}])
        | state_type: "completed"
      }
    ]

    payload = Presenter.board_payload(fn -> {:ok, issues} end, orch_name(), 1_000)
    done = Enum.find(payload.columns, &(&1.key == "done"))
    assert Enum.any?(done.issues, &(&1.identifier == "SODEV-1"))
  end
end
