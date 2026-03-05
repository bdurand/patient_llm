# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::LLM::Chat do
  let(:chat) do
    described_class.new(
      callback: TestCallback,
      model: "gpt-4",
      provider: "openai"
    )
  end

  describe "#initialize" do
    it "sets the callback" do
      expect(chat.callback).to eq(TestCallback)
    end

    it "sets the model" do
      expect(chat.model).to eq("gpt-4")
    end

    it "sets the provider" do
      expect(chat.provider).to eq("openai")
    end

    it "initializes with empty messages" do
      expect(chat.messages).to eq([])
    end

    it "preserves temperature when passed" do
      chat = described_class.new(callback: TestCallback, temperature: 0.7)
      expect(chat.temperature).to eq(0.7)
    end

    it "preserves thinking_effort when passed" do
      chat = described_class.new(callback: TestCallback, thinking_effort: "high")
      expect(chat.thinking_effort).to eq("high")
    end

    it "preserves thinking_budget when passed" do
      chat = described_class.new(callback: TestCallback, thinking_budget: 10_000)
      expect(chat.thinking_budget).to eq(10_000)
    end

    it "initializes with empty tools" do
      expect(chat.tools).to eq({})
    end

    it "defaults max_tool_iterations to 25" do
      expect(chat.max_tool_iterations).to eq(25)
    end

    it "registers tools when passed to constructor" do
      chat = described_class.new(callback: TestCallback, tools: [WeatherTool])
      expect(chat.tools.keys).to eq([:weather])
    end

    it "sets max_tool_iterations when passed" do
      chat = described_class.new(callback: TestCallback, max_tool_iterations: 10)
      expect(chat.max_tool_iterations).to eq(10)
    end
  end

  describe "#with_instructions" do
    it "adds a system message at the top" do
      chat.with_instructions("You are helpful")
      expect(chat.messages).to eq([{role: :system, content: "You are helpful"}])
    end

    it "returns self for chaining" do
      expect(chat.with_instructions("test")).to eq(chat)
    end

    it "adds system messages before non-system messages" do
      chat.add_message(role: :user, content: "Hello")
      chat.with_instructions("You are helpful")
      expect(chat.messages.first[:role]).to eq(:system)
      expect(chat.messages.last[:role]).to eq(:user)
    end

    it "adds new system messages after existing system messages" do
      chat.with_instructions("First")
      chat.add_message(role: :user, content: "Hello")
      chat.with_instructions("Second")
      expect(chat.messages[0]).to eq({role: :system, content: "First"})
      expect(chat.messages[1]).to eq({role: :system, content: "Second"})
      expect(chat.messages[2]).to eq({role: :user, content: "Hello"})
    end

    context "with replace: true" do
      it "replaces existing system messages and puts new one at top" do
        chat.with_instructions("First")
        chat.add_message(role: :user, content: "Hello")
        chat.with_instructions("Second", replace: true)
        expect(chat.messages.count { |m| m[:role] == :system }).to eq(1)
        expect(chat.messages.first[:content]).to eq("Second")
        expect(chat.messages.last[:role]).to eq(:user)
      end
    end
  end

  describe "#with_temperature" do
    it "sets the temperature" do
      chat.with_temperature(0.7)
      expect(chat.temperature).to eq(0.7)
    end

    it "returns self for chaining" do
      expect(chat.with_temperature(0.5)).to eq(chat)
    end
  end

  describe "#with_model" do
    it "sets the model" do
      chat.with_model("claude-3-opus")
      expect(chat.model).to eq("claude-3-opus")
    end

    it "optionally sets the provider" do
      chat.with_model("claude-3-opus", provider: :anthropic)
      expect(chat.model).to eq("claude-3-opus")
      expect(chat.provider).to eq("anthropic")
    end

    it "returns self for chaining" do
      expect(chat.with_model("test")).to eq(chat)
    end
  end

  describe "#with_api_base" do
    it "sets the api_base" do
      chat.with_api_base("http://localhost:1234")
      expect(chat.api_base).to eq("http://localhost:1234")
    end

    it "returns self for chaining" do
      expect(chat.with_api_base("http://localhost:1234")).to eq(chat)
    end
  end

  describe "#with_thinking" do
    it "sets thinking with effort" do
      chat.with_thinking(effort: "high")
      expect(chat.thinking).to eq({effort: "high", budget: nil})
    end

    it "sets thinking with budget" do
      chat.with_thinking(budget: 10_000)
      expect(chat.thinking).to eq({effort: nil, budget: 10_000})
    end

    it "sets thinking with both" do
      chat.with_thinking(effort: "medium", budget: 5000)
      expect(chat.thinking).to eq({effort: "medium", budget: 5000})
    end

    it "returns self for chaining" do
      expect(chat.with_thinking(effort: "low")).to eq(chat)
    end
  end

  describe "#without_thinking" do
    it "clears thinking configuration" do
      chat.with_thinking(effort: "high", budget: 10_000)
      chat.without_thinking
      expect(chat.thinking).to be_nil
    end

    it "returns self for chaining" do
      expect(chat.without_thinking).to eq(chat)
    end
  end

  describe "#with_schema" do
    it "sets a hash schema" do
      schema = {type: "object", properties: {name: {type: "string"}}}
      chat.with_schema(schema)
      expect(chat.schema).to eq(schema)
    end

    it "extracts schema from objects with #to_json_schema" do
      schema_obj = double(to_json_schema: {schema: {type: "object"}})
      chat.with_schema(schema_obj)
      expect(chat.schema).to eq({type: "object"})
    end

    it "returns self for chaining" do
      expect(chat.with_schema({})).to eq(chat)
    end
  end

  describe "#with_params" do
    it "merges params" do
      chat.with_params(foo: "bar")
      chat.with_params(baz: "qux")
      expect(chat.params).to eq({foo: "bar", baz: "qux"})
    end

    it "returns self for chaining" do
      expect(chat.with_params(a: 1)).to eq(chat)
    end
  end

  describe "#with_headers" do
    it "merges headers" do
      chat.with_headers("X-Custom" => "value")
      chat.with_headers("X-Another" => "value2")
      expect(chat.headers).to eq({"X-Custom" => "value", "X-Another" => "value2"})
    end

    it "returns self for chaining" do
      expect(chat.with_headers("X-Test" => "value")).to eq(chat)
    end
  end

  describe "#with_tool" do
    it "registers a tool class" do
      chat.with_tool(WeatherTool)
      expect(chat.tools.keys).to eq([:weather])
      expect(chat.tools[:weather]).to be_a(WeatherTool)
    end

    it "registers a tool instance" do
      tool = WeatherTool.new
      chat.with_tool(tool)
      expect(chat.tools[:weather]).to equal(tool)
    end

    it "returns self for chaining" do
      expect(chat.with_tool(WeatherTool)).to eq(chat)
    end
  end

  describe "#with_tools" do
    it "registers multiple tools" do
      chat.with_tools(WeatherTool, CalculatorTool)
      expect(chat.tools.keys).to contain_exactly(:weather, :calculator)
    end

    it "returns self for chaining" do
      expect(chat.with_tools(WeatherTool)).to eq(chat)
    end
  end

  describe "#with_max_tool_iterations" do
    it "sets the max iterations" do
      chat.with_max_tool_iterations(10)
      expect(chat.max_tool_iterations).to eq(10)
    end

    it "returns self for chaining" do
      expect(chat.with_max_tool_iterations(5)).to eq(chat)
    end
  end

  describe "#build_payload (private)" do
    it "deep merges nested params into the provider payload" do
      chat.with_params(response_format: {json_schema: {strict: true}})

      model_info = double("model")
      provider_instance = instance_double("RubyLLM::Provider")
      rendered_payload = {
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "response",
            strict: false
          }
        },
        stream: false
      }

      allow(provider_instance).to receive(:send)
        .with(:render_payload, [], hash_including(model: model_info, stream: false))
        .and_return(rendered_payload)

      payload = chat.send(:build_payload, model_info, provider_instance)

      expect(payload).to eq(
        response_format: {
          type: "json_schema",
          json_schema: {
            name: "response",
            strict: true
          }
        },
        stream: false
      )
    end

    it "passes tools to the provider" do
      chat.with_tool(WeatherTool)

      model_info = double("model")
      provider_instance = instance_double("RubyLLM::Provider")

      allow(provider_instance).to receive(:send)
        .with(:render_payload, anything, hash_including(tools: chat.tools))
        .and_return({})

      chat.send(:build_payload, model_info, provider_instance)

      expect(provider_instance).to have_received(:send)
        .with(:render_payload, anything, hash_including(tools: chat.tools))
    end
  end

  describe "#add_message" do
    it "adds a hash message" do
      chat.add_message(role: :user, content: "Hello")
      expect(chat.messages).to eq([{role: :user, content: "Hello"}])
    end

    it "adds a message with string keys" do
      chat.add_message("role" => "user", "content" => "Hello")
      expect(chat.messages).to eq([{role: :user, content: "Hello"}])
    end

    it "adds a message-like object" do
      message = double(role: :assistant, content: "Hi there")
      chat.add_message(message)
      expect(chat.messages).to eq([{role: :assistant, content: "Hi there"}])
    end

    it "returns self for chaining" do
      expect(chat.add_message(role: :user, content: "test")).to eq(chat)
    end

    it "preserves tool_calls from a message-like object" do
      tool_call = RubyLLM::ToolCall.new(id: "call_1", name: "weather", arguments: {city: "SF"})
      message = double(role: :assistant, content: "", tool_calls: {"call_1" => tool_call}, tool_call_id: nil)
      chat.add_message(message)

      stored = chat.messages.last
      expect(stored[:tool_calls]).to be_a(Hash)
      expect(stored[:tool_calls]["call_1"][:name]).to eq("weather")
    end

    it "preserves tool_call_id from a message-like object" do
      message = double(role: :tool, content: "72°F", tool_calls: nil, tool_call_id: "call_1")
      chat.add_message(message)

      stored = chat.messages.last
      expect(stored[:tool_call_id]).to eq("call_1")
    end

    it "preserves tool_calls from a hash" do
      chat.add_message(
        role: :assistant,
        content: "",
        tool_calls: {
          "call_1" => {"id" => "call_1", "name" => "weather", "arguments" => {"city" => "SF"}}
        }
      )

      stored = chat.messages.last
      expect(stored[:tool_calls]["call_1"]["name"]).to eq("weather")
    end

    it "preserves tool_call_id from a hash" do
      chat.add_message(role: :tool, content: "72°F", tool_call_id: "call_1")

      stored = chat.messages.last
      expect(stored[:tool_call_id]).to eq("call_1")
    end

    it "accepts assistant messages with tool_calls and empty content" do
      chat.add_message(
        role: :assistant,
        content: nil,
        tool_calls: {
          "call_1" => {"id" => "call_1", "name" => "weather", "arguments" => {}}
        }
      )

      stored = chat.messages.last
      expect(stored[:role]).to eq(:assistant)
      expect(stored[:content]).to eq("")
    end
  end

  describe "#reset_messages!" do
    it "clears all messages" do
      chat.add_message(role: :user, content: "Hello")
      chat.reset_messages!
      expect(chat.messages).to eq([])
    end

    it "returns self for chaining" do
      expect(chat.reset_messages!).to eq(chat)
    end
  end

  describe "#as_json / #dump" do
    before do
      chat.with_instructions("Be helpful")
      chat.add_message(role: :user, content: "Hello")
      chat.with_temperature(0.8)
      chat.with_thinking(effort: "high")
      chat.with_schema({type: "object"})
      chat.with_params(top_p: 0.9)
      chat.with_headers("X-Custom" => "value")
    end

    it "serializes to a hash" do
      json = chat.as_json
      expect(json["v"]).to eq(PatientHttp::LLM::Chat::SERIALIZATION_VERSION)
      expect(json["callback"]).to eq("TestCallback")
      expect(json["model"]).to eq("gpt-4")
      expect(json["provider"]).to eq("openai")
      expect(json["messages"]).to eq([
        {"role" => "system", "content" => "Be helpful"},
        {"role" => "user", "content" => "Hello"}
      ])
      expect(json["temperature"]).to eq(0.8)
      expect(json["thinking_effort"]).to eq("high")
      expect(json["thinking_budget"]).to be_nil
      expect(json["schema"]).to eq({"type" => "object"})
      expect(json["params"]).to eq({"top_p" => 0.9})
      expect(json["headers"]).to eq({"X-Custom" => "value"})
    end

    it "aliases dump to as_json" do
      expect(chat.dump).to eq(chat.as_json)
    end

    it "includes tools when present" do
      chat.with_tool(WeatherTool)
      json = chat.as_json
      expect(json["tools"]).to eq(["WeatherTool"])
    end

    it "omits tools when none registered" do
      json = chat.as_json
      expect(json).not_to have_key("tools")
    end

    it "includes max_tool_iterations when non-default" do
      chat.with_max_tool_iterations(10)
      json = chat.as_json
      expect(json["max_tool_iterations"]).to eq(10)
    end

    it "omits max_tool_iterations when default" do
      json = chat.as_json
      expect(json).not_to have_key("max_tool_iterations")
    end

    it "serializes tool_calls in messages" do
      chat.add_message(
        role: :assistant,
        content: "",
        tool_calls: {
          "call_1" => {"id" => "call_1", "name" => "weather", "arguments" => {"city" => "SF"}}
        }
      )

      json = chat.as_json
      msg = json["messages"].last
      expect(msg["tool_calls"]).to eq({
        "call_1" => {"id" => "call_1", "name" => "weather",
                     "arguments" => {"city" => "SF"}}
      })
    end

    it "serializes tool_call_id in messages" do
      chat.add_message(role: :tool, content: "72°F", tool_call_id: "call_1")

      json = chat.as_json
      msg = json["messages"].last
      expect(msg["tool_call_id"]).to eq("call_1")
    end
  end

  describe ".load" do
    let(:serialized) do
      {
        "v" => 1,
        "callback" => "TestCallback",
        "model" => "gpt-4",
        "provider" => "openai",
        "messages" => [
          {"role" => "system", "content" => "Be helpful"},
          {"role" => "user", "content" => "Hello"}
        ],
        "temperature" => 0.8,
        "thinking_effort" => "high",
        "thinking_budget" => nil,
        "schema" => {"type" => "object"},
        "params" => {"top_p" => 0.9},
        "headers" => {"X-Custom" => "value"}
      }
    end

    it "deserializes a chat" do
      loaded = described_class.load(serialized)
      expect(loaded.callback).to eq("TestCallback")
      expect(loaded.model).to eq("gpt-4")
      expect(loaded.provider).to eq("openai")
      expect(loaded.messages).to eq([
        {role: :system, content: "Be helpful"},
        {role: :user, content: "Hello"}
      ])
      expect(loaded.temperature).to eq(0.8)
      expect(loaded.thinking).to eq({effort: "high", budget: nil})
      expect(loaded.schema).to eq({"type" => "object"})
      expect(loaded.params).to eq({"top_p" => 0.9})
      expect(loaded.headers).to eq({"X-Custom" => "value"})
    end

    it "handles symbol keys" do
      sym_serialized = serialized.transform_keys(&:to_sym)
      loaded = described_class.load(sym_serialized)
      expect(loaded.model).to eq("gpt-4")
    end

    it "roundtrips correctly" do
      chat.with_instructions("Test")
      chat.add_message(role: :user, content: "Hi")
      chat.with_temperature(0.5)

      loaded = described_class.load(chat.as_json)
      expect(loaded.as_json).to eq(chat.as_json)
    end

    it "deserializes tools" do
      data = serialized.merge("tools" => %w[WeatherTool CalculatorTool])
      loaded = described_class.load(data)
      expect(loaded.tools.keys).to contain_exactly(:weather, :calculator)
      expect(loaded.tools[:weather]).to be_a(WeatherTool)
    end

    it "deserializes max_tool_iterations" do
      data = serialized.merge("max_tool_iterations" => 10)
      loaded = described_class.load(data)
      expect(loaded.max_tool_iterations).to eq(10)
    end

    it "deserializes messages with tool_calls" do
      data = serialized.merge(
        "messages" => [
          {
            "role" => "assistant",
            "content" => "",
            "tool_calls" => {
              "call_1" => {"id" => "call_1", "name" => "weather", "arguments" => {"city" => "SF"}}
            }
          }
        ]
      )

      loaded = described_class.load(data)
      msg = loaded.messages.first
      expect(msg[:tool_calls]).to be_a(Hash)
      expect(msg[:tool_calls]["call_1"]["name"]).to eq("weather")
    end

    it "deserializes messages with tool_call_id" do
      data = serialized.merge(
        "messages" => [
          {"role" => "tool", "content" => "72°F", "tool_call_id" => "call_1"}
        ]
      )

      loaded = described_class.load(data)
      msg = loaded.messages.first
      expect(msg[:role]).to eq(:tool)
      expect(msg[:tool_call_id]).to eq("call_1")
    end

    it "roundtrips tool messages correctly" do
      chat.with_tool(WeatherTool)
      chat.add_message(
        role: :assistant,
        content: "",
        tool_calls: {
          "call_1" => {"id" => "call_1", "name" => "weather", "arguments" => {"city" => "SF"}}
        }
      )
      chat.add_message(role: :tool, content: "72°F", tool_call_id: "call_1")

      loaded = described_class.load(chat.as_json)
      expect(loaded.as_json).to eq(chat.as_json)
    end
  end
end
