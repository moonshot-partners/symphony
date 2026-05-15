defmodule SymphonyElixir.Orchestrator.RetryAttemptsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator.{RetryAttempts, State}

  defp empty_state(overrides \\ %{}) do
    Map.merge(
      %State{
        running: %{},
        claimed: MapSet.new(),
        workpads: %{},
        retry_attempts: %{},
        tick_timer_ref: nil,
        tick_token: nil,
        next_poll_due_at_ms: nil,
        poll_interval_ms: 1,
        max_concurrent_agents: 1
      },
      overrides
    )
  end

  describe "schedule/5" do
    test "arms a timer, populates retry_attempts entry, and delivers :retry_issue to recipient" do
      state = empty_state()

      metadata = %{
        identifier: "ISS-1",
        error: "boom",
        worker_host: "host-a",
        workspace_path: "/tmp/ws",
        delay_type: :continuation
      }

      updated = RetryAttempts.schedule(state, "issue-1", 1, metadata, self())

      assert %{
               attempt: 1,
               timer_ref: timer_ref,
               retry_token: retry_token,
               due_at_ms: due_at_ms,
               identifier: "ISS-1",
               error: "boom",
               worker_host: "host-a",
               workspace_path: "/tmp/ws"
             } = Map.fetch!(updated.retry_attempts, "issue-1")

      assert is_reference(timer_ref)
      assert is_reference(retry_token)
      assert is_integer(due_at_ms)

      assert_receive {:retry_issue, "issue-1", ^retry_token}, 2_000
    end

    test "cancels the previous timer reference when one is already armed for the same issue" do
      previous_ref = Process.send_after(self(), :stale_retry, 50_000)

      state =
        empty_state(%{
          retry_attempts: %{
            "issue-1" => %{
              attempt: 2,
              timer_ref: previous_ref,
              retry_token: make_ref()
            }
          }
        })

      updated =
        RetryAttempts.schedule(
          state,
          "issue-1",
          1,
          %{identifier: "ISS-1", delay_type: :continuation},
          self()
        )

      refute is_integer(Process.read_timer(previous_ref))
      assert updated.retry_attempts["issue-1"].attempt == 1
      assert_receive {:retry_issue, "issue-1", _token}, 2_000
    end
  end

  describe "pop/3" do
    test "returns {:ok, attempt, metadata, new_state} when retry_token matches and clears entry" do
      retry_token = make_ref()

      state =
        empty_state(%{
          retry_attempts: %{
            "issue-1" => %{
              attempt: 4,
              timer_ref: make_ref(),
              retry_token: retry_token,
              identifier: "ISS-1",
              error: "boom",
              worker_host: "host-a",
              workspace_path: "/tmp/ws"
            }
          }
        })

      assert {:ok, 4, metadata, new_state} = RetryAttempts.pop(state, "issue-1", retry_token)

      assert metadata == %{
               identifier: "ISS-1",
               error: "boom",
               worker_host: "host-a",
               workspace_path: "/tmp/ws"
             }

      refute Map.has_key?(new_state.retry_attempts, "issue-1")
    end

    test "returns :missing when retry_token does not match the latest schedule" do
      state =
        empty_state(%{
          retry_attempts: %{
            "issue-1" => %{
              attempt: 1,
              timer_ref: make_ref(),
              retry_token: make_ref()
            }
          }
        })

      assert :missing == RetryAttempts.pop(state, "issue-1", make_ref())
      assert Map.has_key?(state.retry_attempts, "issue-1")
    end

    test "returns :missing when there is no retry entry for the issue" do
      state = empty_state()
      assert :missing == RetryAttempts.pop(state, "issue-unknown", make_ref())
    end
  end
end
