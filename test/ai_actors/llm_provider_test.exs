defmodule AiActors.LLMProviderTest do
  use ExUnit.Case, async: true

  alias AiActors.LLMProvider

  describe "get_provider/1" do
    test "returns Anthropic provider for :anthropic" do
      assert LLMProvider.get_provider(:anthropic) == AiActors.LLMProvider.Anthropic
    end

    test "returns OpenRouter provider for :openrouter" do
      assert LLMProvider.get_provider(:openrouter) == AiActors.LLMProvider.OpenRouter
    end

    test "returns Ollama provider for :ollama" do
      assert LLMProvider.get_provider(:ollama) == AiActors.LLMProvider.Ollama
    end

    test "returns nil for unknown provider" do
      assert LLMProvider.get_provider(:unknown) == nil
    end
  end

  describe "find_provider_for_model/1" do
    test "finds Anthropic for Claude models" do
      assert LLMProvider.find_provider_for_model(:sonnet) == :anthropic
      assert LLMProvider.find_provider_for_model(:haiku) == :anthropic
      assert LLMProvider.find_provider_for_model(:opus) == :anthropic
    end

    test "finds OpenRouter for Cerebras models" do
      assert LLMProvider.find_provider_for_model(:cerebras_llama70b) == :openrouter
      assert LLMProvider.find_provider_for_model(:cerebras_llama8b) == :openrouter
    end

    test "finds OpenRouter for SambaNova models" do
      assert LLMProvider.find_provider_for_model(:sambanova_llama405b) == :openrouter
      assert LLMProvider.find_provider_for_model(:sambanova_llama70b) == :openrouter
    end

    test "finds Ollama for Granite models" do
      assert LLMProvider.find_provider_for_model(:granite_micro) == :ollama
      assert LLMProvider.find_provider_for_model(:granite_small) == :ollama
      assert LLMProvider.find_provider_for_model(:granite_tiny) == :ollama
    end

    test "returns nil for unknown model" do
      assert LLMProvider.find_provider_for_model(:unknown_model) == nil
    end
  end

  describe "resolve_api_key/1" do
    test "resolves from environment variable" do
      System.put_env("TEST_API_KEY", "test-value")
      assert LLMProvider.resolve_api_key({:system, "TEST_API_KEY"}) == "test-value"
      System.delete_env("TEST_API_KEY")
    end

    test "returns string keys directly" do
      assert LLMProvider.resolve_api_key("direct-key") == "direct-key"
    end

    test "returns nil for invalid input" do
      assert LLMProvider.resolve_api_key(123) == nil
      assert LLMProvider.resolve_api_key(nil) == nil
    end
  end
end

defmodule AiActors.LLMProvider.AnthropicTest do
  use ExUnit.Case, async: true

  alias AiActors.LLMProvider.Anthropic

  describe "supported_models/0" do
    test "returns list of supported model aliases" do
      models = Anthropic.supported_models()

      assert is_list(models)
      assert :sonnet in models
      assert :haiku in models
      assert :opus in models
    end
  end

  describe "default_model/0" do
    test "returns :sonnet as default" do
      assert Anthropic.default_model() == :sonnet
    end
  end

  describe "model_string/1" do
    test "converts alias to full model string" do
      assert Anthropic.model_string(:sonnet) == "claude-sonnet-4-5-20250929"
      assert Anthropic.model_string(:haiku) == "claude-haiku-4-5-20250929"
    end

    test "passes through string models unchanged" do
      assert Anthropic.model_string("custom-model") == "custom-model"
    end
  end
end

defmodule AiActors.LLMProvider.OpenRouterTest do
  use ExUnit.Case, async: true

  alias AiActors.LLMProvider.OpenRouter

  describe "supported_models/0" do
    test "returns list of supported model aliases" do
      models = OpenRouter.supported_models()

      assert is_list(models)
      assert :cerebras_llama70b in models
      assert :sambanova_llama405b in models
      assert :groq_llama70b in models
    end
  end

  describe "default_model/0" do
    test "returns :cerebras_llama70b as default" do
      assert OpenRouter.default_model() == :cerebras_llama70b
    end
  end

  describe "model_string/1" do
    test "converts alias to full model string" do
      assert OpenRouter.model_string(:cerebras_llama70b) == "cerebras/llama-3.3-70b"
      assert OpenRouter.model_string(:sambanova_llama405b) == "sambanova/llama-3.1-405b-instruct"
    end

    test "passes through string models unchanged" do
      assert OpenRouter.model_string("custom/model") == "custom/model"
    end
  end
end

defmodule AiActors.LLMProvider.OllamaTest do
  use ExUnit.Case, async: true

  alias AiActors.LLMProvider.Ollama

  describe "supported_models/0" do
    test "returns list of supported model aliases" do
      models = Ollama.supported_models()

      assert is_list(models)
      assert :granite_micro in models
      assert :granite_small in models
      assert :llama3_8b in models
    end
  end

  describe "default_model/0" do
    test "returns :granite_micro as default" do
      assert Ollama.default_model() == :granite_micro
    end
  end

  describe "model_string/1" do
    test "converts alias to full model string" do
      assert Ollama.model_string(:granite_micro) == "granite4:small-h"
      assert Ollama.model_string(:llama3_8b) == "llama3.1:8b"
    end

    test "passes through string models unchanged" do
      assert Ollama.model_string("custom:latest") == "custom:latest"
    end
  end
end
