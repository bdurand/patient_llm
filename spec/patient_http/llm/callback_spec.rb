# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::LLM::Callback do
  let(:callback) { described_class.new }

  let(:session_hash) do
    {
      "model" => "gpt-4",
      "input" => [
        {"type" => "message", "role" => "user", "content" => [{"type" => "input_text", "text" => "Hello"}]}
      ]
    }
  end

  let(:callback_args) do
    {
      session: session_hash,
      provider: "openai",
      callback: "TestCallback",
      custom: {"user_id" => "123"},
      request_options: {},
      tool_iteration: 0
    }
  end

  describe "#on_complete" do
    let(:response_body) do
      {
        "choices" => [
          {"message" => {"role" => "assistant", "content" => "Hello! How can I help?"}}
        ],
        "usage" => {"prompt_tokens" => 10, "completion_tokens" => 8},
        "model" => "gpt-4"
      }
    end

    let(:response) do
      PatientHttp::Response.new(
        callback_args: callback_args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate(response_body),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )
    end

    let(:test_callback_instance) { TestCallback.new }

    before do
      allow(TestCallback).to receive(:new).and_return(test_callback_instance)
      allow(test_callback_instance).to receive(:on_complete)
    end

    it "restores the session from callback_args" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |session, _provider, _msg, _args, _resp|
        expect(session).to be_a(PromptBuilder::Session)
        expect(session.model).to eq("gpt-4")
      end
    end

    it "passes the provider name" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |_session, provider, _msg, _args, _resp|
        expect(provider).to eq("openai")
      end
    end

    it "parses the response into a PromptBuilder::Response" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |_session, _provider, llm_response, _args, _resp|
        expect(llm_response).to be_a(PromptBuilder::Response)
        expect(llm_response.text).to eq("Hello! How can I help?")
      end
    end

    it "calls the user callback with session, provider, llm_response, callback_args, and response" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete)
        .with(
          instance_of(PromptBuilder::Session),
          "openai",
          instance_of(PromptBuilder::Response),
          instance_of(PatientHttp::CallbackArgs),
          response
        )
    end

    it "passes custom callback_args to the user callback" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |_session, _provider, _msg, args, _resp|
        expect(args[:user_id]).to eq("123")
      end
    end

    it "includes the response in the session passed to the user callback" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |session, _provider, _msg, _args, _resp|
        # The session should contain the original user message plus the assistant response
        messages = session.items.select { |i| i.is_a?(PromptBuilder::Items::Message) }
        roles = messages.map(&:role)
        expect(roles).to include("user", "assistant")
      end
    end
  end

  describe "#on_error" do
    let(:error) do
      instance_double(
        PatientHttp::Error,
        callback_args: callback_args,
        error_type: :http_error,
        message: "Connection failed"
      )
    end

    let(:test_callback_instance) { TestCallback.new }

    before do
      allow(PatientHttp::ClassHelper).to receive(:resolve_class_name)
        .with("TestCallback")
        .and_return(TestCallback)

      allow(TestCallback).to receive(:new).and_return(test_callback_instance)
      allow(test_callback_instance).to receive(:on_error)
    end

    it "restores the session from callback_args" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error) do |session, _provider, _args, _error|
        expect(session).to be_a(PromptBuilder::Session)
        expect(session.model).to eq("gpt-4")
      end
    end

    it "calls the user callback with session, provider, callback_args, and error" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error)
        .with(
          instance_of(PromptBuilder::Session),
          "openai",
          instance_of(PatientHttp::CallbackArgs),
          error
        )
    end

    it "passes custom callback_args to the user callback" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error) do |_session, _provider, args, _error|
        expect(args[:user_id]).to eq("123")
      end
    end
  end

  describe "non-JSON responses" do
    let(:bad_response) do
      PatientHttp::Response.new(
        callback_args: callback_args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 502,
        headers: {"content-type" => "text/html"},
        body: "<html>Bad Gateway</html>",
        duration: 1.0,
        request_id: SecureRandom.uuid
      )
    end

    it "raises a descriptive error when the body is not JSON" do
      expect { callback.on_complete(bad_response) }
        .to raise_error(RuntimeError, /Invalid JSON response/)
    end
  end

  describe "missing callback" do
    let(:args_without_callback) do
      {session: session_hash, provider: "openai", callback: nil, custom: {}, request_options: {}}
    end

    let(:response) do
      PatientHttp::Response.new(
        callback_args: args_without_callback,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: '{"choices":[{"message":{"role":"assistant","content":"hi"}}]}',
        duration: 1.0,
        request_id: SecureRandom.uuid
      )
    end

    it "raises a clear error when callback is missing" do
      expect { callback.on_complete(response) }
        .to raise_error(ArgumentError, /No callback registered/)
    end
  end

  describe "auto tool loop" do
    before do
      PromptBuilder.register_tool("auto_weather", description: "weather", parameters: {type: "object", properties: {"location" => {type: "string"}}, required: ["location"]}) do |args|
        "72F in #{args["location"]}"
      end
    end

    after do
      PromptBuilder.reset_tool_registry!
    end

    let(:session_with_tools) do
      session = PromptBuilder::Session.new(model: "gpt-4")
      session.user("Hello")
      session.register_tool("auto_weather", description: "weather", parameters: {type: "object", properties: {"location" => {type: "string"}}, required: ["location"]})
      session.to_h
    end

    let(:callback_args_with_tools) do
      {
        session: session_with_tools,
        provider: "openai",
        callback: "TestCallback",
        custom: {"user_id" => "123"},
        request_options: {},
        tool_iteration: 0
      }
    end

    let(:tool_call_body) do
      {
        "choices" => [
          {
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_1",
                  "type" => "function",
                  "function" => {"name" => "auto_weather", "arguments" => '{"location":"NYC"}'}
                }
              ]
            }
          }
        ],
        "usage" => {"prompt_tokens" => 5, "completion_tokens" => 5},
        "model" => "gpt-4"
      }
    end

    let(:tool_call_response) do
      PatientHttp::Response.new(
        callback_args: callback_args_with_tools,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate(tool_call_body),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )
    end

    it "executes the tool and re-asks without calling the user callback" do
      captured = nil
      fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
        captured = {request: request, callback_args: callback_args}
        "req-id"
      }

      PatientHttp.register_handler(fake_handler)
      begin
        test_callback = instance_double(TestCallback, on_complete: nil)
        allow(TestCallback).to receive(:new).and_return(test_callback)

        callback.on_complete(tool_call_response)

        expect(test_callback).not_to have_received(:on_complete)
        expect(captured).not_to be_nil
        expect(captured[:callback_args][:tool_iteration]).to eq(1)
      ensure
        PatientHttp.unregister_handler
      end
    end

    it "raises when MAX_TOOL_ITERATIONS is exceeded" do
      args = callback_args_with_tools.merge(tool_iteration: PatientHttp::LLM::Callback::MAX_TOOL_ITERATIONS)
      response = PatientHttp::Response.new(
        callback_args: args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate(tool_call_body),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )

      expect { callback.on_complete(response) }
        .to raise_error(RuntimeError, /Tool-call loop exceeded/)
    end

    it "JSON-encodes structured tool results" do
      PromptBuilder.reset_tool_registry!
      PromptBuilder.register_tool("structured", description: "structured", parameters: {type: "object", properties: {"q" => {type: "string"}}, required: ["q"]}) do |args|
        {temperature: 72, condition: "sunny", query: args["q"]}
      end

      session = PromptBuilder::Session.new(model: "gpt-4")
      session.user("Hello")
      session.register_tool("structured", description: "structured", parameters: {type: "object", properties: {"q" => {type: "string"}}, required: ["q"]})

      args = {
        session: session.to_h,
        provider: "openai",
        callback: "TestCallback",
        custom: {},
        request_options: {},
        tool_iteration: 0
      }

      body = {
        "choices" => [
          {
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_struct",
                  "type" => "function",
                  "function" => {"name" => "structured", "arguments" => '{"q":"NYC"}'}
                }
              ]
            }
          }
        ],
        "usage" => {"prompt_tokens" => 5, "completion_tokens" => 5},
        "model" => "gpt-4"
      }

      response = PatientHttp::Response.new(
        callback_args: args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate(body),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )

      captured = nil
      fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
        captured = callback_args
        "req-id"
      }

      PatientHttp.register_handler(fake_handler)
      begin
        callback.on_complete(response)

        # Verify the re-ask happened and the session contains valid JSON tool output
        expect(captured).not_to be_nil
        session_data = captured[:session]
        tool_outputs = session_data["input"].select { |i| i["type"] == "function_call_output" }
        expect(tool_outputs.size).to eq(1)
        output = tool_outputs.first["output"]
        parsed = JSON.parse(output)
        expect(parsed["temperature"]).to eq(72)
        expect(parsed["condition"]).to eq("sunny")
      ensure
        PatientHttp.unregister_handler
      end
    end

    it "handles HaltError with nil content gracefully" do
      PromptBuilder.reset_tool_registry!
      PromptBuilder.register_tool("halt_nil", description: "halt", parameters: {type: "object", properties: {"x" => {type: "string"}}, required: ["x"]}) do |_args|
        raise PatientHttp::LLM::HaltError.new
      end

      session = PromptBuilder::Session.new(model: "gpt-4")
      session.user("Hello")
      session.register_tool("halt_nil", description: "halt", parameters: {type: "object", properties: {"x" => {type: "string"}}, required: ["x"]})

      args = {
        session: session.to_h,
        provider: "openai",
        callback: "TestCallback",
        custom: {},
        request_options: {},
        tool_iteration: 0
      }

      body = {
        "choices" => [
          {
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_nil",
                  "type" => "function",
                  "function" => {"name" => "halt_nil", "arguments" => '{"x":"go"}'}
                }
              ]
            }
          }
        ],
        "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1},
        "model" => "gpt-4"
      }

      response = PatientHttp::Response.new(
        callback_args: args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate(body),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )

      test_callback = instance_double(TestCallback, on_complete: nil)
      allow(TestCallback).to receive(:new).and_return(test_callback)

      callback.on_complete(response)

      expect(test_callback).to have_received(:on_complete) do |_session, _provider, llm_response, _args, _resp|
        expect(llm_response).to be_a(PromptBuilder::Response)
        expect(llm_response.text).to eq("")
      end
    end

    it "surfaces HaltError content as the final assistant message without re-asking" do
      PromptBuilder.reset_tool_registry!
      PromptBuilder.register_tool("halting", description: "halting", parameters: {type: "object", properties: {"x" => {type: "string"}}, required: ["x"]}) do |args|
        raise PatientHttp::LLM::HaltError.new(content: "Stopped: #{args["x"]}")
      end

      session = PromptBuilder::Session.new(model: "gpt-4")
      session.user("Hello")
      session.register_tool("halting", description: "halting", parameters: {type: "object", properties: {"x" => {type: "string"}}, required: ["x"]})

      args = {
        session: session.to_h,
        provider: "openai",
        callback: "TestCallback",
        custom: {"user_id" => "123"},
        request_options: {},
        tool_iteration: 0
      }

      body = {
        "choices" => [
          {
            "message" => {
              "role" => "assistant",
              "content" => nil,
              "tool_calls" => [
                {
                  "id" => "call_halt",
                  "type" => "function",
                  "function" => {"name" => "halting", "arguments" => '{"x":"go"}'}
                }
              ]
            }
          }
        ],
        "usage" => {"prompt_tokens" => 1, "completion_tokens" => 1},
        "model" => "gpt-4"
      }

      response = PatientHttp::Response.new(
        callback_args: args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate(body),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )

      test_callback = instance_double(TestCallback, on_complete: nil)
      allow(TestCallback).to receive(:new).and_return(test_callback)

      callback.on_complete(response)

      expect(test_callback).to have_received(:on_complete) do |_session, _provider, llm_response, _args, _resp|
        expect(llm_response).to be_a(PromptBuilder::Response)
        expect(llm_response.text).to eq("Stopped: go")
      end
    end
  end
end
