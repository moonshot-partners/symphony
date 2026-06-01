# Silence the DecisionLog by default in the test suite — orchestrator tests
# would otherwise append to /opt/symphony/state/decisions.jsonl on the dev box.
# DecisionLog tests opt back in via path: keyword, which bypasses the env gate
# only when the call sites supply one. The dedicated DecisionLogTest cases that
# exercise the env gate set/unset SYMPHONY_DECISION_LOG inline.
System.put_env("SYMPHONY_DECISION_LOG", "0")

# Completion summaries + QA evidence publish to on-box cockpit stores. Point them
# at tmp in the suite so orchestrator/completion tests never write to
# /opt/symphony. Tests that assert store contents override these in setup.
System.put_env("SYMPHONY_COCKPIT_EVIDENCE_DIR", Path.join(System.tmp_dir!(), "symphony-test-evidence"))
System.put_env("SYMPHONY_COCKPIT_SUMMARY_DIR", Path.join(System.tmp_dir!(), "symphony-test-summaries"))

ExUnit.start()
Code.require_file("support/test_support.exs", __DIR__)
