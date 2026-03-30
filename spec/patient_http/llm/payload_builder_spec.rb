# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::LLM::PayloadBuilder do
  describe ".build" do
    it "builds a basic payload with model and messages" do
      payload = described_class.build(
        messages: [{role: :user, content: "Hello"}],
        model: "gpt-4"
      )

      expect(payload[:model]).to eq("gpt-4")
      expect(payload[:messages]).to eq([{role: "user", content: "Hello"}])
    end

    it "includes temperature when provided" do
      payload = described_class.build(
        messages: [{role: :user, content: "Hello"}],
        model: "gpt-4",
        temperature: 0.7
      )

      expect(payload[:temperature]).to eq(0.7)
    end

    it "omits temperature when nil" do
      payload = described_class.build(
        messages: [{role: :user, content: "Hello"}],
        model: "gpt-4"
      )

      expect(payload).not_to have_key(:temperature)
    end

    it "builds tools array from tool instances" do
      tool = WeatherTool.new
      payload = described_class.build(
        messages: [{role: :user, content: "What's the weather?"}],
        model: "gpt-4",
        tools: [tool]
      )

      expect(payload[:tools]).to eq([{
        type: "function",
        function: {
          name: "weather",
          description: "Get the current weather for a location",
          parameters: tool.parameters
        }
      }])
    end

    it "omits tools when nil" do
      payload = described_class.build(
        messages: [{role: :user, content: "Hello"}],
        model: "gpt-4"
      )

      expect(payload).not_to have_key(:tools)
    end

    it "builds schema as response_format" do
      schema = {type: "object", properties: {name: {type: "string"}}}
      payload = described_class.build(
        messages: [{role: :user, content: "Hello"}],
        model: "gpt-4",
        schema: schema
      )

      expect(payload[:response_format]).to eq({
        type: "json_schema",
        json_schema: {name: "response", schema: schema}
      })
    end

    it "maps thinking effort to reasoning_effort" do
      payload = described_class.build(
        messages: [{role: :user, content: "Hello"}],
        model: "gpt-4",
        thinking: {effort: "high", budget: nil}
      )

      expect(payload[:reasoning_effort]).to eq("high")
      expect(payload).not_to have_key(:max_completion_tokens)
    end

    it "maps thinking budget to max_completion_tokens" do
      payload = described_class.build(
        messages: [{role: :user, content: "Hello"}],
        model: "gpt-4",
        thinking: {effort: nil, budget: 10000}
      )

      expect(payload[:max_completion_tokens]).to eq(10000)
      expect(payload).not_to have_key(:reasoning_effort)
    end

    it "handles messages with tool_calls" do
      messages = [
        {role: :user, content: "What's the weather?"},
        {
          role: :assistant,
          content: nil,
          tool_calls: {
            "call_123" => {name: "weather", arguments: {location: "NYC"}}
          }
        }
      ]

      payload = described_class.build(messages: messages, model: "gpt-4")
      assistant_msg = payload[:messages][1]

      expect(assistant_msg[:tool_calls]).to be_an(Array)
      expect(assistant_msg[:tool_calls][0][:id]).to eq("call_123")
      expect(assistant_msg[:tool_calls][0][:type]).to eq("function")
      expect(assistant_msg[:tool_calls][0][:function][:name]).to eq("weather")
    end

    it "handles messages with tool_call_id" do
      messages = [
        {role: :tool, content: "72°F and sunny", tool_call_id: "call_123"}
      ]

      payload = described_class.build(messages: messages, model: "gpt-4")
      expect(payload[:messages][0][:tool_call_id]).to eq("call_123")
    end
  end
end
