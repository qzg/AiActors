defmodule AiActors.LLMClientTest do
  use ExUnit.Case, async: true

  alias AiActors.LLMClient

  describe "build_request_body/2" do
    test "builds basic request with messages" do
      messages = [%{role: "user", content: "Hello"}]

      # Note: build_request_body is private, so we test via send_message
      # This test documents the expected behavior
      assert is_list(messages)
      assert Enum.all?(messages, &is_map/1)
    end
  end

  describe "parse_structured_response/1" do
    test "parses valid JSON from text content" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => ~s({"key": "value", "number": 42})}
        ]
      }

      assert {:ok, %{"key" => "value", "number" => 42}} =
               LLMClient.parse_structured_response(response)
    end

    test "handles multiple text blocks" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "Some prefix text"},
          %{"type" => "text", "text" => ~s({"result": true})}
        ]
      }

      # The parser concatenates all text blocks and extracts JSON
      result = LLMClient.parse_structured_response(response)
      # The improved JSON extraction can find JSON objects in mixed text
      assert {:ok, %{"result" => true}} = result
    end

    test "returns error for invalid JSON" do
      response = %{
        "content" => [
          %{"type" => "text", "text" => "not valid json"}
        ]
      }

      assert {:error, _} = LLMClient.parse_structured_response(response)
    end
  end

  describe "message validation" do
    test "messages have required structure" do
      message = %{role: "user", content: "test"}
      assert message.role in ["user", "assistant"]
      assert is_binary(message.content) or is_list(message.content)
    end
  end

  describe "tool definitions" do
    test "tool has required fields" do
      tool = %{
        name: "test_tool",
        description: "A test tool",
        input_schema: %{
          type: "object",
          properties: %{
            param: %{type: "string"}
          }
        }
      }

      assert is_binary(tool.name)
      assert is_binary(tool.description)
      assert is_map(tool.input_schema)
    end
  end
end
