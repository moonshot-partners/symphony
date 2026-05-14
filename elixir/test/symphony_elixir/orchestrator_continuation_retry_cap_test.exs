defmodule SymphonyElixir.OrchestratorContinuationRetryCapTest do
  @moduledoc """
  Regression coverage for SODEV-883: the continuation retry loop must stop after
  one retry when the issue already has an open PR attachment (has_pr_attachment=true
  and retry_attempt >= 1). This prevents infinite agent restarts when CI fails for
  infra reasons the agent cannot fix (e.g. Anthropic rate limit on scope-discipline).

  Contract:
  - has_pr_attachment=true, retry_attempt >= 1, :normal exit → NO continuation retry
  - has_pr_attachment=true, retry_attempt == 0, :normal exit → ONE continuation retry (SODEV-765 protection)
  - has_pr_attachment=false, :normal exit → continuation retry (existing behavior)
  """

  use SymphonyElixir.TestSupport

  defp start_orchestrator(name) do
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp running_entry(ref, opts) do
    issue_id = Keyword.get(opts, :issue_id, "issue-cap-test")
    identifier = Keyword.get(opts, :identifier, "MT-CAP")
    has_pr = Keyword.get(opts, :has_pr_attachment, false)
    retry_attempt = Keyword.get(opts, :retry_attempt, 0)

    %{
      pid: self(),
      ref: ref,
      identifier: identifier,
      retry_attempt: retry_attempt,
      issue: %Issue{
        id: issue_id,
        identifier: identifier,
        state: "In Development",
        has_pr_attachment: has_pr
      },
      started_at: DateTime.utc_now()
    }
  end

  test "no continuation retry when PR attached and retry_attempt >= 1" do
    issue_id = "issue-cap-pr-retry1"
    ref = make_ref()
    pid = start_orchestrator(Module.concat(__MODULE__, :CapPrRetry1))

    initial_state = :sys.get_state(pid)
    entry = running_entry(ref, issue_id: issue_id, identifier: "MT-CAP-1", has_pr_attachment: true, retry_attempt: 1)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)

    refute Map.has_key?(state.retry_attempts, issue_id),
           "expected no continuation retry but got: #{inspect(state.retry_attempts[issue_id])}"
  end

  test "no continuation retry when PR attached and retry_attempt >= 2" do
    issue_id = "issue-cap-pr-retry2"
    ref = make_ref()
    pid = start_orchestrator(Module.concat(__MODULE__, :CapPrRetry2))

    initial_state = :sys.get_state(pid)
    entry = running_entry(ref, issue_id: issue_id, identifier: "MT-CAP-2", has_pr_attachment: true, retry_attempt: 2)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.retry_attempts, issue_id)
  end

  test "continuation retry scheduled when PR attached and retry_attempt == 0 (SODEV-765 protection)" do
    issue_id = "issue-cap-pr-retry0"
    ref = make_ref()
    pid = start_orchestrator(Module.concat(__MODULE__, :CapPrRetry0))

    initial_state = :sys.get_state(pid)
    entry = running_entry(ref, issue_id: issue_id, identifier: "MT-CAP-0", has_pr_attachment: true, retry_attempt: 0)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1} = state.retry_attempts[issue_id],
           "expected one continuation retry (SODEV-765 protection) but got: #{inspect(state.retry_attempts[issue_id])}"
  end

  test "continuation retry scheduled when no PR attached" do
    issue_id = "issue-cap-no-pr"
    ref = make_ref()
    pid = start_orchestrator(Module.concat(__MODULE__, :CapNoPr))

    initial_state = :sys.get_state(pid)
    entry = running_entry(ref, issue_id: issue_id, identifier: "MT-CAP-NP", has_pr_attachment: false, retry_attempt: 0)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1} = state.retry_attempts[issue_id],
           "expected continuation retry when no PR attached"
  end

  test "abnormal exit retry path unchanged (crash with PR attached still retries)" do
    issue_id = "issue-cap-crash-pr"
    ref = make_ref()
    pid = start_orchestrator(Module.concat(__MODULE__, :CapCrashPr))

    initial_state = :sys.get_state(pid)
    entry = running_entry(ref, issue_id: issue_id, identifier: "MT-CAP-CR", has_pr_attachment: true, retry_attempt: 1)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 2, error: "agent exited: :boom"} = state.retry_attempts[issue_id],
           "crash retry path must be unchanged by PR cap"
  end
end
