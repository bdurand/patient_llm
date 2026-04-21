# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::LLM::ResponseParser do
  describe ".parse" do
    it "parses a text response" do
      body = {
        "choices" => [
          {"message" => {"role" => "assistant", "content" => "Hello!"}}
        ],
        "usage" => {"prompt_tokens" => 10, "completion_tokens" => 5},
        "model" => "gpt-4"
      }

      message = described_class.parse(body)

      expect(message).to be_a(PatientHttp::LLM::Message)
      expect(message.role).to eq(:assistant)
      expect(message.content).to eq("Hello!")
      expect(message.model_id).to eq("gpt-4")
      expect(message.input_tokens).to eq(10)
      expect(message.output_tokens).to eq(5)
      expect(message.tool_call?).to be false
    end

    it "parses a response with tool calls" do
      body = {
        "choices" => [
          {
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_abc",
                  "type" => "function",
                  "function" => {
                    "name" => "weather",
                    "arguments" => '{"location":"NYC","units":"fahrenheit"}'
                  }
                }
              ]
            }
          }
        ],
        "usage" => {"prompt_tokens" => 15, "completion_tokens" => 20},
        "model" => "gpt-4"
      }

      message = described_class.parse(body)

      expect(message.tool_call?).to be true
      expect(message.tool_calls).to have_key("call_abc")

      tc = message.tool_calls["call_abc"]
      expect(tc).to be_a(PatientHttp::LLM::ToolCall)
      expect(tc.name).to eq("weather")
      expect(tc.arguments).to eq({location: "NYC", units: "fahrenheit"})
    end

    it "handles missing usage gracefully" do
      body = {
        "choices" => [
          {"message" => {"role" => "assistant", "content" => "Hi"}}
        ]
      }

      message = described_class.parse(body)
      expect(message.input_tokens).to be_nil
      expect(message.output_tokens).to be_nil
    end

    it "preserves raw arguments when JSON is malformed" do
      body = {
        "choices" => [
          {
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_bad",
                  "type" => "function",
                  "function" => {"name" => "weather", "arguments" => "{not valid json"}
                }
              ]
            }
          }
        ]
      }

      message = described_class.parse(body)
      expect(message.tool_calls["call_bad"].arguments).to eq("{not valid json")
    end

    it "handles empty tool_calls" do
      body = {
        "choices" => [
          {"message" => {"role" => "assistant", "content" => "Sure", "tool_calls" => []}}
        ],
        "usage" => {"prompt_tokens" => 5, "completion_tokens" => 3}
      }

      message = described_class.parse(body)
      expect(message.tool_call?).to be false
    end
  end
end
