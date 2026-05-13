defmodule SymphonyElixir.QaHelpersTest do
  @moduledoc """
  Runs the Python stdlib unittest suite that lives next to `qa_helpers.py`.
  Keeps the QA harness's HTTP-shaped logic under CI without bringing Python
  into the Elixir test runner — we just shell out and assert exit 0.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @qa_dir Path.join([@repo_root, "docker", "schoolsout-base", "qa"])

  describe "docker/schoolsout-base/qa/test_qa_helpers.py" do
    test "python3 -m unittest passes" do
      {output, status} =
        System.cmd("python3", ["-m", "unittest", "test_qa_helpers.py"],
          cd: @qa_dir,
          stderr_to_stdout: true
        )

      assert status == 0, "qa_helpers python tests failed:\n#{output}"
    end
  end
end
