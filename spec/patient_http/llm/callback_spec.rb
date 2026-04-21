# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::LLM::Callback do
  let(:callback) { described_class.new }

  let(:chat_data) do
    {
      "v" => 1,
      "callback" => "TestCallback",
      "model" => "gpt-4",
      "provider" => "openai",
      "api_base" => "https://api.openai.com",
      "messages" => [
        {"role" => "user", "content" => "Hello"}
      ]
    }
  end

  let(:callback_args) do
    {
      chat: chat_data,
      chat_callback: "TestCallback",
      custom: {"user_id" => "123"}
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

    it "loads the chat from callback_args" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |chat, _message, _args, _response|
        expect(chat).to be_a(PatientHttp::LLM::Chat)
        expect(chat.model).to eq("gpt-4")
        expect(chat.provider).to eq("openai")
      end
    end

    it "parses the response into a Message" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |_chat, message, _args, _response|
        expect(message).to be_a(PatientHttp::LLM::Message)
        expect(message.role).to eq(:assistant)
        expect(message.content).to eq("Hello! How can I help?")
        expect(message.input_tokens).to eq(10)
        expect(message.output_tokens).to eq(8)
        expect(message.model_id).to eq("gpt-4")
      end
    end

    it "calls the user callback with chat, message, callback_args, and response" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete)
        .with(
          instance_of(PatientHttp::LLM::Chat),
          instance_of(PatientHttp::LLM::Message),
          instance_of(PatientHttp::CallbackArgs),
          response
        )
    end

    it "passes custom callback_args to the user callback" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |_chat, _message, args, _response|
        expect(args[:user_id]).to eq("123")
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

    it "loads the chat from callback_args" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error) do |chat, _args, _error|
        expect(chat).to be_a(PatientHttp::LLM::Chat)
        expect(chat.model).to eq("gpt-4")
      end
    end

    it "calls the user callback with chat, callback_args, and error" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error)
        .with(
          instance_of(PatientHttp::LLM::Chat),
          instance_of(PatientHttp::CallbackArgs),
          error
        )
    end

    it "passes custom callback_args to the user callback" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error) do |_chat, args, _error|
        expect(args[:user_id]).to eq("123")
      end
    end
  end

  describe "#chat_callback_args (private)" do
    it "wraps custom args in CallbackArgs" do
      custom_args = {"user_id" => "123", "session_id" => "abc"}
      args = callback.send(:chat_callback_args, {custom: custom_args})

      expect(args).to be_a(PatientHttp::CallbackArgs)
      expect(args[:user_id]).to eq("123")
      expect(args[:session_id]).to eq("abc")
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

  describe "missing chat_callback" do
    let(:args_without_callback) do
      {chat: chat_data, chat_callback: nil, custom: {}}
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

    it "raises a clear error when chat_callback is missing" do
      expect { callback.on_complete(response) }
        .to raise_error(ArgumentError, /No chat_callback registered/)
    end
  end

  describe "auto tool loop" do
    before do
      stub_const(
        "AutoWeatherTool",
        Class.new(PatientHttp::LLM::Tool) do
          description "weather"
          param :location, type: "string", desc: "City"

          def execute(location:)
            "72F in #{location}"
          end
        end
      )
    end

    let(:chat_data_with_tools) do
      chat_data.merge("tools" => ["AutoWeatherTool"])
    end

    let(:callback_args_with_tools) do
      {
        chat: chat_data_with_tools,
        chat_callback: "TestCallback",
        custom: {"user_id" => "123"},
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

        # Tool call + tool result appended to chat
        messages = captured[:callback_args][:chat]["messages"]
        expect(messages.last["role"]).to eq("tool")
        expect(messages.last["content"]).to eq("72F in NYC")
        expect(messages.last["tool_call_id"]).to eq("call_1")
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

    it "surfaces Tool::Halt content as the final assistant message without re-asking" do
      stub_const(
        "HaltingTool",
        Class.new(PatientHttp::LLM::Tool) do
          description "halting"
          param :x, type: "string", desc: "x"

          def execute(x:)
            halt("Stopped: #{x}")
          end
        end
      )

      args = callback_args_with_tools.merge(
        chat: chat_data_with_tools.merge("tools" => ["HaltingTool"])
      )

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

      # Should not need a handler — halt short-circuits the re-ask
      callback.on_complete(response)

      expect(test_callback).to have_received(:on_complete) do |_chat, message, _args, _response|
        expect(message).to be_a(PatientHttp::LLM::Message)
        expect(message.content).to eq("Stopped: go")
      end
    end
  end
end
