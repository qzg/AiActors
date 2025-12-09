defmodule AiActors.Examples.LearningCounterActorTest do
  use ExUnit.Case, async: false

  alias AiActors.Examples.LearningCounterActor
  alias AiActors.EscalationTracker

  setup do
    # Ensure services are started
    start_supervised!(AiActors.CodeModifier)
    start_supervised!(EscalationTracker)

    :ok
  end

  describe "LearningCounterActor" do
    test "initializes with self-learning enabled" do
      {:ok, pid} = LearningCounterActor.start_link(0)

      assert Process.alive?(pid)
      assert LearningCounterActor.enable_self_learning?() == true

      GenServer.stop(pid)
    end

    test "has self-learning configuration" do
      config = LearningCounterActor.self_learning_config()

      assert is_map(config)
      assert Map.has_key?(config, :review_interval_hours)
      assert Map.has_key?(config, :min_escalations_for_analysis)
    end

    test "handles explicit operations" do
      {:ok, pid} = LearningCounterActor.start_link(0)

      assert 5 == GenServer.call(pid, {:increment, 5})
      assert 3 == GenServer.call(pid, {:decrement, 2})
      assert 3 == GenServer.call(pid, :get_value)

      GenServer.stop(pid)
    end

    test "logs handler executions" do
      {:ok, pid} = LearningCounterActor.start_link(0)

      GenServer.call(pid, {:increment, 5})
      GenServer.call(pid, {:decrement, 2})

      Process.sleep(50)

      stats = EscalationTracker.get_statistics(LearningCounterActor)

      assert stats.total_handler_executions >= 2

      GenServer.stop(pid)
    end

    test "can retrieve learning statistics" do
      {:ok, pid} = LearningCounterActor.start_link(0)

      GenServer.call(pid, {:increment, 5})

      Process.sleep(50)

      stats = LearningCounterActor.learning_stats(pid)

      assert is_map(stats)
      assert Map.has_key?(stats, :statistics)
      assert Map.has_key?(stats, :report)

      GenServer.stop(pid)
    end

    test "generates learning report" do
      report = LearningCounterActor.learning_report()

      assert is_map(report)
      assert report.module == LearningCounterActor
      assert Map.has_key?(report, :learning_status)
    end

    test "can manually trigger review" do
      {:ok, pid} = LearningCounterActor.start_link(0)

      # Log some escalations first (would need real LLM in integration test)
      # For unit test, just verify the trigger works
      result = LearningCounterActor.review(pid)

      # Should return analysis result
      assert {:ok, analysis} = result
      assert is_map(analysis)

      GenServer.stop(pid)
    end

    test "development metadata indicates learning" do
      {:ok, pid} = LearningCounterActor.start_link(0)

      metadata = LearningCounterActor.get_metadata(pid)

      assert metadata.custom_metadata.learning_enabled == true
      assert is_list(metadata.custom_metadata.learnable_operations)

      GenServer.stop(pid)
    end
  end

  describe "Learning workflow" do
    @tag :integration
    @tag timeout: 60_000
    test "actor learns from escalations over time" do
      {:ok, pid} = LearningCounterActor.start_link(0)

      # Simulate repeated unknown operations
      # In a real scenario with LLM, these would escalate
      # For testing, we can simulate by logging escalations directly

      for _i <- 1..6 do
        EscalationTracker.log_escalation(
          LearningCounterActor,
          pid,
          {:multiply, 2},
          :call,
          {:ok, %{"action" => "reply", "value" => 10}},
          150
        )
      end

      Process.sleep(100)

      # Trigger pattern analysis
      {:ok, analysis} = EscalationTracker.analyze_patterns(LearningCounterActor)

      # Should identify the multiply pattern
      assert length(analysis.patterns_found) >= 1

      GenServer.stop(pid)
    end
  end
end
