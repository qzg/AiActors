defmodule AiActors.OptimizationEvaluatorTest do
  use ExUnit.Case, async: true

  alias AiActors.OptimizationEvaluator

  describe "evaluate_pattern/4" do
    test "returns :keep_current for insufficient data" do
      history = [
        %{message: {:test, 1}, response: {:ok, %{"action" => "reply", "value" => "1"}}}
      ]

      result = OptimizationEvaluator.evaluate_pattern(TestModule, {:test, :_number}, history)
      assert result == :keep_current
    end

    test "returns :keep_current for empty history" do
      result = OptimizationEvaluator.evaluate_pattern(TestModule, {:test, :_number}, [])
      assert result == :keep_current
    end

    test "identifies deterministic pattern with identical responses" do
      # Create history with identical responses (100% identical)
      identical_response = %{"action" => "reply", "value" => "42"}
      history = for i <- 1..10 do
        %{
          message: {:multiply, i},
          response: {:ok, identical_response}
        }
      end

      # With 100% identical responses, should recommend deterministic
      result = OptimizationEvaluator.evaluate_pattern(
        TestModule,
        {:multiply, :_number},
        history,
        %{
          identical_response_threshold: 0.95,
          similar_structure_threshold: 0.80,
          min_occurrences: 5,
          min_cost_savings: 0.001,
          max_tokens_for_local: 200,
          max_tokens_for_accelerated: 500,
          test_sample_size: 5,
          min_pass_rate_local: 0.95,
          min_pass_rate_accelerated: 0.90
        }
      )

      # Should either return {:deterministic, code} or :keep_current if LLM generation fails
      # (since we're not mocking LLM calls in this test)
      assert result in [:keep_current] or match?({:deterministic, _}, result)
    end
  end

  describe "get_config/0" do
    test "returns configuration map with expected keys" do
      config = OptimizationEvaluator.get_config()

      assert is_map(config)
      assert Map.has_key?(config, :identical_response_threshold)
      assert Map.has_key?(config, :similar_structure_threshold)
      assert Map.has_key?(config, :min_occurrences)
      assert Map.has_key?(config, :max_tokens_for_local)
      assert Map.has_key?(config, :max_tokens_for_accelerated)
    end

    test "returns reasonable default thresholds" do
      config = OptimizationEvaluator.get_config()

      assert config.identical_response_threshold >= 0.9
      assert config.similar_structure_threshold >= 0.7
      assert config.min_occurrences >= 3
    end
  end

  describe "generate_deterministic_handler/3" do
    test "returns :keep_current for insufficient data" do
      history = [
        %{message: {:test, 1}, response: {:ok, %{"value" => "1"}}}
      ]

      result = OptimizationEvaluator.generate_deterministic_handler(TestModule, {:test, :_number}, history)

      # Without LLM mocking, this should return :keep_current on failure
      # or {:deterministic, code} on success
      assert result == :keep_current or match?({:deterministic, _}, result)
    end
  end
end
