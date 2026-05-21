# Silence the DecisionLog by default in the test suite — orchestrator tests
# would otherwise append to /opt/symphony/state/decisions.jsonl on the dev box.
# DecisionLog tests opt back in via path: keyword, which bypasses the env gate
# only when the call sites supply one. The dedicated DecisionLogTest cases that
# exercise the env gate set/unset SYMPHONY_DECISION_LOG inline.
System.put_env("SYMPHONY_DECISION_LOG", "0")

ExUnit.start()
Code.require_file("support/test_support.exs", __DIR__)
