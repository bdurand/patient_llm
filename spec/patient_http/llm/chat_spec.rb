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
    it "sets thinking effort" do
      chat.with_thinking(effort: "high")
      expect(chat.thinking).to eq({effort: "high"})
    end

    it "stringifies symbol effort" do
      chat.with_thinking(effort: :medium)
      expect(chat.thinking).to eq({effort: "medium"})
    end

    it "returns self for chaining" do
      expect(chat.with_thinking(effort: "low")).to eq(chat)
    end
  end

  describe "#without_thinking" do
    it "clears thinking configuration" do
      chat.with_thinking(effort: "high")
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

  describe "#build_payload (private)" do
    it "builds an OpenAI-format payload" do
      chat.add_message(role: :user, content: "Hello")
      payload = chat.send(:build_payload)

      expect(payload[:model]).to eq("gpt-4")
      expect(payload[:messages]).to eq([{role: "user", content: "Hello"}])
    end

    it "deep merges params into the payload" do
      chat.with_schema({type: "object"})
      chat.with_params(response_format: {json_schema: {strict: true}})

      chat.add_message(role: :user, content: "Hello")
      payload = chat.send(:build_payload)

      expect(payload[:response_format]).to eq({
        type: "json_schema",
        json_schema: {name: "response", schema: {type: "object"}, strict: true}
      })
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
      message = double(role: :assistant, content: "Hi there", tool_calls: {}, tool_call_id: nil)
      chat.add_message(message)
      expect(chat.messages).to eq([{role: :assistant, content: "Hi there"}])
    end

    it "adds a Message with tool_calls" do
      tool_call = PatientHttp::LLM::ToolCall.new(id: "tc_1", name: "weather", arguments: {location: "NYC"})
      message = PatientHttp::LLM::Message.new(role: :assistant, content: nil, tool_calls: {"tc_1" => tool_call})
      chat.add_message(message)
      expect(chat.messages.last[:tool_calls]).to eq({"tc_1" => tool_call})
    end

    it "returns self for chaining" do
      expect(chat.add_message(role: :user, content: "test")).to eq(chat)
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

  describe "#completion_path" do
    it "defaults to /v1/chat/completions" do
      expect(chat.completion_path).to eq("/v1/chat/completions")
    end

    it "uses explicit completion_path when set" do
      chat = described_class.new(callback: TestCallback, completion_path: "/custom/path")
      expect(chat.completion_path).to eq("/custom/path")
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
      expect(json).not_to have_key("thinking_budget")
      expect(json["schema"]).to eq({"type" => "object"})
      expect(json["params"]).to eq({"top_p" => 0.9})
      expect(json["headers"]).to eq({"X-Custom" => "value"})
      expect(json["tools"]).to eq([])
    end

    it "aliases dump to as_json" do
      expect(chat.dump).to eq(chat.as_json)
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
      expect(loaded.thinking).to eq({effort: "high"})
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
  end

  describe "tool-call round trip" do
    let(:tool_call) do
      PatientHttp::LLM::ToolCall.new(
        id: "call_1",
        name: "weather",
        arguments: {location: "NYC"}
      )
    end

    let(:assistant_msg) do
      PatientHttp::LLM::Message.new(
        role: :assistant,
        content: nil,
        tool_calls: {"call_1" => tool_call}
      )
    end

    it "allows assistant messages with nil content + tool_calls to round-trip" do
      chat.add_message(assistant_msg)
      chat.add_message(role: :tool, content: "72F", tool_call_id: "call_1")

      loaded = described_class.load(chat.as_json)

      tc_msg = loaded.messages.find { |m| m[:role] == :assistant && m[:tool_calls] }
      expect(tc_msg[:content]).to be_nil
      expect(tc_msg[:tool_calls]["call_1"]).to be_a(PatientHttp::LLM::ToolCall)
      expect(tc_msg[:tool_calls]["call_1"].name).to eq("weather")
      expect(tc_msg[:tool_calls]["call_1"].arguments).to eq({"location" => "NYC"})

      tool_msg = loaded.messages.find { |m| m[:role] == :tool }
      expect(tool_msg[:tool_call_id]).to eq("call_1")
      expect(tool_msg[:content]).to eq("72F")
    end

    it "serializes tool_calls as plain JSON-native hashes" do
      chat.add_message(assistant_msg)
      tool_calls_json = chat.as_json["messages"].last["tool_calls"]

      tc_hash = tool_calls_json["call_1"]
      expect(tc_hash).to be_a(Hash)
      expect(tc_hash["name"]).to eq("weather")
      expect(tc_hash["arguments"]).to eq({"location" => "NYC"})
    end

    it "builds a correct payload after a load cycle" do
      chat.add_message(assistant_msg)
      chat.add_message(role: :tool, content: "72F", tool_call_id: "call_1")

      loaded = described_class.load(chat.as_json)
      payload = loaded.send(:build_payload)

      assistant = payload[:messages].find { |m| m[:role] == "assistant" }
      expect(assistant[:tool_calls][0][:function][:name]).to eq("weather")
      expect(JSON.parse(assistant[:tool_calls][0][:function][:arguments])).to eq({"location" => "NYC"})
    end

    it "raises when a message hash is missing role, content, tool_calls, and tool_call_id" do
      expect {
        chat.add_message(role: :user)
      }.to raise_error(ArgumentError, /must have content, tool_calls, or tool_call_id/)
    end
  end

  describe "tool persistence" do
    before do
      stub_const(
        "PersistedTool",
        Class.new(PatientHttp::LLM::Tool) do
          description "persisted"
        end
      )
    end

    it "serializes tools as class names" do
      chat.with_tools([PersistedTool.new])
      expect(chat.as_json["tools"]).to eq(["PersistedTool"])
    end

    it "rehydrates tools from class names" do
      chat.with_tools([PersistedTool.new])
      loaded = described_class.load(chat.as_json)
      expect(loaded.tools.map { |t| t.class }).to eq([PersistedTool])
    end

    it "accepts Tool classes directly via with_tools" do
      chat.with_tools([PersistedTool])
      expect(chat.tools.map(&:class)).to eq([PersistedTool])
    end

    it "raises for an unknown tool class name" do
      expect {
        described_class.load("callback" => "TestCallback", "tools" => ["NoSuchTool"])
      }.to raise_error(NameError)
    end
  end

  describe "URL composition" do
    it "joins api_base and completion_path with a single slash, preserving base path" do
      chat.with_api_base("http://localhost:1234/api/v1")
      url = chat.send(:join_url, chat.api_base, "/v1/chat/completions")
      expect(url).to eq("http://localhost:1234/api/v1/v1/chat/completions")
    end

    it "normalizes trailing slash on base" do
      chat.with_api_base("http://localhost:1234/")
      url = chat.send(:join_url, chat.api_base, "/v1/chat/completions")
      expect(url).to eq("http://localhost:1234/v1/chat/completions")
    end

    it "normalizes missing leading slash on path" do
      chat.with_api_base("http://localhost:1234")
      url = chat.send(:join_url, chat.api_base, "v1/chat/completions")
      expect(url).to eq("http://localhost:1234/v1/chat/completions")
    end
  end
end
