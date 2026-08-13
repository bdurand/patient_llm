# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM::Callback do
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

      expect(test_callback_instance).to have_received(:on_complete) do |session:, **|
        expect(session).to be_a(PromptBuilder::Session)
        expect(session.model).to eq("gpt-4")
      end
    end

    it "passes the provider name" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |provider:, **|
        expect(provider).to eq("openai")
      end
    end

    it "parses the response into a PromptBuilder::Response" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |llm_response:, **|
        expect(llm_response).to be_a(PromptBuilder::Response)
        expect(llm_response.text).to eq("Hello! How can I help?")
      end
    end

    it "calls the user callback with session, provider, llm_response, callback_args, and response" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete)
        .with(
          session: instance_of(PromptBuilder::Session),
          provider: "openai",
          llm_response: instance_of(PromptBuilder::Response),
          callback_args: instance_of(PatientHttp::CallbackArgs),
          http_response: response,
          request_id: anything
        )
    end

    it "passes custom callback_args to the user callback" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |callback_args:, **|
        expect(callback_args[:user_id]).to eq("123")
      end
    end

    it "includes the response in the session passed to the user callback" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |session:, **|
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

      expect(test_callback_instance).to have_received(:on_error) do |session:, **|
        expect(session).to be_a(PromptBuilder::Session)
        expect(session.model).to eq("gpt-4")
      end
    end

    it "calls the user callback with session, provider, callback_args, and error" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error)
        .with(
          session: instance_of(PromptBuilder::Session),
          provider: "openai",
          callback_args: instance_of(PatientHttp::CallbackArgs),
          error: error,
          http_response: nil,
          request_id: anything
        )
    end

    it "passes custom callback_args to the user callback" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error) do |callback_args:, **|
        expect(callback_args[:user_id]).to eq("123")
      end
    end

    it "falls back to the HTTP response's request id when original_request_id is nil" do
      http_response = PatientHttp::Response.new(
        callback_args: callback_args.merge(original_request_id: nil),
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 500,
        headers: {},
        body: "boom",
        duration: 1.0,
        request_id: "req-http-1"
      )
      http_error = instance_double(
        PatientHttp::HttpError,
        callback_args: callback_args.merge(original_request_id: nil),
        response: http_response
      )

      callback.on_error(http_error)

      expect(test_callback_instance).to have_received(:on_error) do |request_id:, **|
        expect(request_id).to eq("req-http-1")
      end
    end

    it "prefers the original request id from the callback args" do
      http_response = PatientHttp::Response.new(
        callback_args: callback_args.merge(original_request_id: "req-original"),
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 500,
        headers: {},
        body: "boom",
        duration: 1.0,
        request_id: "req-http-2"
      )
      http_error = instance_double(
        PatientHttp::HttpError,
        callback_args: callback_args.merge(original_request_id: "req-original"),
        response: http_response
      )

      callback.on_error(http_error)

      expect(test_callback_instance).to have_received(:on_error) do |request_id:, **|
        expect(request_id).to eq("req-original")
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
        .to raise_error(RuntimeError, /Content-Type is not application\/json/)
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

    it "restores the preprocessors override when re-asking after tool execution" do
      args = callback_args_with_tools.merge(request_options: {"preprocessors" => ["aws_sigv4"]})
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

      captured = nil
      fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
        captured = {request: request, callback_args: callback_args}
        "req-id"
      }

      PatientHttp.register_handler(fake_handler)
      begin
        test_callback = instance_double(TestCallback, on_complete: nil)
        allow(TestCallback).to receive(:new).and_return(test_callback)

        callback.on_complete(response)

        expect(captured).not_to be_nil
        expect(captured[:request].preprocessors).to eq(["aws_sigv4"])
      ensure
        PatientHttp.unregister_handler
      end
    end

    it "parses the response with the serializer bound in callback_args even when the provider config differs" do
      # Regression: the serializer resolved at enqueue must win over the
      # worker-side provider configuration to prevent build/parse drift.
      args = callback_args_with_tools.merge(serializer: "chat_completion", provider: "anthropic_drift")
      PatientLLM.configure do |c|
        c.provider :anthropic_drift, url: "https://api.anthropic.com", serializer: :messages
      end

      response = PatientHttp::Response.new(
        callback_args: args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: '{"model":"gpt-4","choices":[{"message":{"role":"assistant","content":"parsed"}}]}',
        duration: 1.0,
        request_id: SecureRandom.uuid
      )

      received = nil
      test_callback = instance_double(TestCallback)
      allow(TestCallback).to receive(:new).and_return(test_callback)
      allow(test_callback).to receive(:on_complete) { |llm_response:, **| received = llm_response.text }

      callback.on_complete(response)

      expect(received).to eq("parsed")
    end

    it "passes the response headers to the parser so the converse response id comes from the request metadata header" do
      args = callback_args.merge(serializer: "converse")
      converse_body = {
        "output" => {
          "message" => {"role" => "assistant", "content" => [{"text" => "Hello!"}]}
        },
        "stopReason" => "end_turn"
      }
      response = PatientHttp::Response.new(
        callback_args: args,
        http_method: :post,
        url: "https://bedrock-runtime.us-east-1.amazonaws.com/model/amazon.nova-pro-v1:0/converse",
        status: 200,
        headers: {"content-type" => "application/json", "x-amzn-RequestId" => "req-123"},
        body: JSON.generate(converse_body),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )

      received = nil
      test_callback = instance_double(TestCallback)
      allow(TestCallback).to receive(:new).and_return(test_callback)
      allow(test_callback).to receive(:on_complete) { |llm_response:, **| received = llm_response.id }

      callback.on_complete(response)

      expect(received).to eq("req-123")
    end

    it "respects a custom max_tool_iterations from callback_args" do
      args = callback_args_with_tools.merge(max_tool_iterations: 2, tool_iteration: 2)
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

      captured_error = nil
      test_callback = instance_double(TestCallback)
      allow(TestCallback).to receive(:new).and_return(test_callback)
      allow(test_callback).to receive(:on_error) { |error:, **| captured_error = error }

      callback.on_complete(response)

      expect(captured_error.error_type).to eq(:max_tool_iterations)
      expect(captured_error.message).to match(/exceeded 2 iterations/)
    end

    it "invokes on_error when MAX_TOOL_ITERATIONS is exceeded" do
      args = callback_args_with_tools.merge(tool_iteration: PatientLLM::Callback::MAX_TOOL_ITERATIONS)
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

      captured_error = nil
      test_callback = instance_double(TestCallback)
      allow(TestCallback).to receive(:new).and_return(test_callback)
      allow(test_callback).to receive(:on_error) { |error:, **| captured_error = error }

      expect { callback.on_complete(response) }.not_to raise_error

      expect(test_callback).to have_received(:on_error)
      expect(captured_error).to be_a(PatientHttp::RequestError)
      expect(captured_error.error_type).to eq(:max_tool_iterations)
      expect(captured_error.error_class).to eq(PatientLLM::MaxToolIterationsError)
      expect(captured_error.message).to match(/Tool-call loop exceeded/)
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
        raise PatientLLM::HaltError.new
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

      expect(test_callback).to have_received(:on_complete) do |llm_response:, **|
        expect(llm_response).to be_a(PromptBuilder::Response)
        expect(llm_response.text).to eq("")
      end
    end

    it "surfaces HaltError content as the final assistant message without re-asking" do
      PromptBuilder.reset_tool_registry!
      PromptBuilder.register_tool("halting", description: "halting", parameters: {type: "object", properties: {"x" => {type: "string"}}, required: ["x"]}) do |args|
        raise PatientLLM::HaltError.new(content: "Stopped: #{args["x"]}")
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

      expect(test_callback).to have_received(:on_complete) do |llm_response:, **|
        expect(llm_response).to be_a(PromptBuilder::Response)
        expect(llm_response.text).to eq("Stopped: go")
      end
    end

    it "adds outputs for tool calls remaining after a HaltError so the session stays continuable" do
      second_tool_invoked = false
      PromptBuilder.reset_tool_registry!
      PromptBuilder.register_tool("halting", description: "halting", parameters: {type: "object", properties: {}}) do |args|
        raise PatientLLM::HaltError.new(content: "Stopped")
      end
      PromptBuilder.register_tool("after_halt", description: "after halt", parameters: {type: "object", properties: {}}) do |args|
        second_tool_invoked = true
        "should not run"
      end

      session = PromptBuilder::Session.new(model: "gpt-4")
      session.user("Hello")
      session.register_tool("halting", description: "halting", parameters: {type: "object", properties: {}})
      session.register_tool("after_halt", description: "after halt", parameters: {type: "object", properties: {}})

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
                {"id" => "call_halt", "type" => "function", "function" => {"name" => "halting", "arguments" => "{}"}},
                {"id" => "call_after", "type" => "function", "function" => {"name" => "after_halt", "arguments" => "{}"}}
              ]
            }
          }
        ],
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

      expect(second_tool_invoked).to be false
      expect(test_callback).to have_received(:on_complete) do |llm_response:, session:, **|
        expect(llm_response.text).to eq("Stopped")

        outputs = session.items.select { |item| item.is_a?(PromptBuilder::Items::FunctionCallOutput) }
        expect(outputs.map(&:call_id)).to eq(["call_halt", "call_after"])
        expect(outputs.last.output).to eq("Tool execution halted")
      end
    end
  end

  describe ".validate_callback_class!" do
    it "accepts a callback declaring a subset of supported keywords" do
      klass = Class.new do
        def on_complete(llm_response:)
        end
      end

      expect { described_class.validate_callback_class!(klass) }.not_to raise_error
    end

    it "accepts a **kwargs-only signature" do
      klass = Class.new do
        def on_complete(**kwargs)
        end

        def on_error(**kwargs)
        end
      end

      expect { described_class.validate_callback_class!(klass) }.not_to raise_error
    end

    it "ignores callback methods that are not defined" do
      klass = Class.new do
        def on_complete(llm_response:)
        end
      end

      expect { described_class.validate_callback_class!(klass) }.not_to raise_error
    end

    it "rejects an unsupported keyword name" do
      klass = Class.new do
        def on_complete(llm_response:, bogus:)
        end
      end

      expect { described_class.validate_callback_class!(klass) }
        .to raise_error(ArgumentError, /unsupported parameter.*:bogus/)
    end

    it "rejects a positional parameter" do
      klass = Class.new do
        def on_complete(llm_response)
        end
      end

      expect { described_class.validate_callback_class!(klass) }
        .to raise_error(ArgumentError, /must use keyword parameters/)
    end

    it "requires error for on_error" do
      klass = Class.new do
        def on_error(session:)
        end
      end

      expect { described_class.validate_callback_class!(klass) }
        .to raise_error(ArgumentError, /must declare the :error keyword/)
    end
  end

  describe "keyword dispatch" do
    let(:capturing_class) do
      Class.new do
        class << self
          attr_accessor :received
        end

        def on_complete(llm_response:)
          self.class.received = {llm_response: llm_response}
        end
      end
    end

    it "passes only the keywords the callback method declares" do
      stub_const("CapturingCallback", capturing_class)

      args = {
        session: session_hash,
        provider: "openai",
        callback: "CapturingCallback",
        custom: {},
        request_options: {},
        tool_iteration: 0
      }

      response = PatientHttp::Response.new(
        callback_args: args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: '{"choices":[{"message":{"role":"assistant","content":"hi"}}],"model":"gpt-4"}',
        duration: 1.0,
        request_id: SecureRandom.uuid
      )

      callback.on_complete(response)

      expect(capturing_class.received.keys).to eq([:llm_response])
      expect(capturing_class.received[:llm_response]).to be_a(PromptBuilder::Response)
    end
  end
end
