defmodule AiActors.SelfLearningTest do
  use ExUnit.Case, async: false

  alias AiActors.SelfLearning
  alias AiActors.EscalationTracker

  setup do
    # Ensure services are started (handle case where application already started them)
    ensure_started(AiActors.CodeModifier)
    ensure_started(EscalationTracker)

    :ok
  end

  defp ensure_started(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  describe "start_learning/2" do
    test "schedules learning reviews" do
      {:ok, pid} = Agent.start_link(fn -> %{} end)

      {:ok, timer_ref} = SelfLearning.start_learning(pid, TestModule)

      assert is_reference(timer_ref)
    end
  end

  describe "generate_report/1" do
    test "generates learning report for module" do
      module = ReportTestModule

      # Add some test data
      EscalationTracker.log_escalation(module, self(), :test, :call, {:ok, %{}}, 100)
      EscalationTracker.log_handler_execution(module, self(), :handler, :test, :ok, 10, true)

      Process.sleep(50)

      report = SelfLearning.generate_report(module)

      assert report.module == module
      assert Map.has_key?(report, :statistics)
      assert Map.has_key?(report, :performance_metrics)
      assert Map.has_key?(report, :learning_status)
    end

    test "determines learning status correctly" do
      module = LearningStatusTestModule

      # Add enough data to progress past learning phase
      for _i <- 1..15 do
        EscalationTracker.log_escalation(module, self(), :test, :call, {:ok, %{}}, 100)
      end

      Process.sleep(50)

      report = SelfLearning.generate_report(module)

      assert report.learning_status in [
               :learning_phase,
               :needs_more_handlers,
               :progressing_well,
               :highly_optimized
             ]
    end
  end

  describe "validate_handlers/2" do
    test "validates handler implementations" do
      module = ValidationTestModule

      implementations = [
        %{
          pattern: "multiply",
          modification_ref: make_ref(),
          implemented_at: DateTime.utc_now(),
          validation_status: :pending
        }
      ]

      # Log some successful executions
      for _i <- 1..5 do
        EscalationTracker.log_handler_execution(
          module,
          self(),
          :multiply_handler,
          {:multiply, 2},
          :ok,
          5,
          true
        )
      end

      Process.sleep(50)

      {:ok, validation} = SelfLearning.validate_handlers(module, implementations)

      assert validation.actor_module == module
      assert is_list(validation.validations)
      assert Map.has_key?(validation, :overall_status)
    end
  end

  describe "implement_recommendations/2" do
    test "handles empty recommendations" do
      analysis = %{recommendations: [], patterns: []}

      {:ok, implementations} = SelfLearning.implement_recommendations(TestModule, analysis)

      assert implementations == []
    end
  end
end
