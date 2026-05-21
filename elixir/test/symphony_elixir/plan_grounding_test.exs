defmodule SymphonyElixir.PlanGroundingTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PlanGrounding

  setup do
    workspace = Path.join(System.tmp_dir!(), "plan_grounding_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(workspace, "app/controllers"))
    File.mkdir_p!(Path.join(workspace, "fe-next-app/components"))
    File.write!(Path.join(workspace, "app/controllers/filter_templates_controller.rb"), "real")
    File.write!(Path.join(workspace, "fe-next-app/components/discovery-links-section.tsx"), "real")

    on_exit(fn -> File.rm_rf!(workspace) end)
    {:ok, workspace: workspace}
  end

  defp plan(body), do: "## Plan\n\n" <> body

  describe "validate/2 — missing plan" do
    test "nil content is a missing-plan violation", %{workspace: ws} do
      assert {:violation, :missing_plan_section} = PlanGrounding.validate(nil, ws)
    end

    test "empty content is a missing-plan violation", %{workspace: ws} do
      assert {:violation, :missing_plan_section} = PlanGrounding.validate("", ws)
    end

    test "content without a ## Plan section is a missing-plan violation", %{workspace: ws} do
      text = """
      ## root_cause

      Something is wrong in `app/controllers/filter_templates_controller.rb:10`.
      """

      assert {:violation, :missing_plan_section} = PlanGrounding.validate(text, ws)
    end
  end

  describe "validate/2 — grounded plan" do
    test "a plan citing one real existing path passes", %{workspace: ws} do
      text = plan("- `app/controllers/filter_templates_controller.rb` — add promote action\n")
      assert :ok = PlanGrounding.validate(text, ws)
    end

    test "a path:line citation suffix is stripped before the existence check", %{workspace: ws} do
      text = plan("- `app/controllers/filter_templates_controller.rb:42` — edit here\n")
      assert :ok = PlanGrounding.validate(text, ws)
    end

    test "a leading ./ is normalized away", %{workspace: ws} do
      text = plan("- `./fe-next-app/components/discovery-links-section.tsx` — wire fallback\n")
      assert :ok = PlanGrounding.validate(text, ws)
    end

    test "a (new)-tagged path is not required to exist", %{workspace: ws} do
      text =
        plan("""
        - `app/controllers/filter_templates_controller.rb` — extend
        - `app/services/promotion_service.rb` (new) — new concern
        """)

      assert :ok = PlanGrounding.validate(text, ws)
    end

    test "non-path backtick tokens are ignored, not treated as missing files", %{workspace: ws} do
      text =
        plan("""
        - `app/controllers/filter_templates_controller.rb` — replace call to `legacy_promote()` and run `git push`
        """)

      assert :ok = PlanGrounding.validate(text, ws)
    end

    test "paths after the next ## header are outside the plan section", %{workspace: ws} do
      text =
        plan("- `app/controllers/filter_templates_controller.rb` — edit\n") <>
          "\n## notes\n\n- `app/does/not/exist.rb` — unrelated\n"

      assert :ok = PlanGrounding.validate(text, ws)
    end
  end

  describe "validate/2 — ungrounded plan" do
    test "a hallucinated path is a path-not-found violation", %{workspace: ws} do
      text = plan("- `app/controllers/filter_modal_controller.rb` — wrong guess\n")

      assert {:violation, {:path_not_found, paths}} = PlanGrounding.validate(text, ws)
      assert "app/controllers/filter_modal_controller.rb" in paths
    end

    test "a real path plus a hallucinated path still fails on the hallucination", %{workspace: ws} do
      text =
        plan("""
        - `app/controllers/filter_templates_controller.rb` — real
        - `fe-next-app/components/FilterModal.tsx` — hallucinated
        """)

      assert {:violation, {:path_not_found, paths}} = PlanGrounding.validate(text, ws)
      assert "fe-next-app/components/FilterModal.tsx" in paths
    end

    test "a plan with only (new) paths and no real anchor is not grounded", %{workspace: ws} do
      text =
        plan("""
        - `app/services/promotion_service.rb` (new) — new
        - `app/services/promotion_policy.rb` (new) — also new
        """)

      assert {:violation, :no_grounded_path} = PlanGrounding.validate(text, ws)
    end

    test "a plan section with no file paths at all is not grounded", %{workspace: ws} do
      text = plan("- The filters modal needs a new option for kids.\n")
      assert {:violation, :no_grounded_path} = PlanGrounding.validate(text, ws)
    end
  end
end
