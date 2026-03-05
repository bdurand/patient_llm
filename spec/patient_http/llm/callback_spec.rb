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
      "completion_path" => "/v1/chat/completions",
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

  let(:provider_instance) do
    instance_double("RubyLLM::Providers::OpenAI")
  end

  before do
    allow(RubyLLM::Models).to receive(:resolve)
      .with("gpt-4", provider: "openai", assume_exists: true)
      .and_return([double("model"), provider_instance])
  end

  def build_response(callback_args:, body: nil)
    body ||= JSON.generate({
      "choices" => [
        {"message" => {"role" => "assistant", "content" => "Hello! How can I help?"}}
      ],
      "usage" => {"prompt_tokens" => 10, "completion_tokens" => 8}
    })

    PatientHttp::Response.new(
      callback_args: callback_args,
      http_method: :post,
      url: "https://api.openai.com/v1/chat/completions",
      status: 200,
      headers: {"content-type" => "application/json"},
      body: body,
      duration: 1.0,
      request_id: SecureRandom.uuid
    )
  end

  describe "#on_complete" do
    context "with a text response (no tool calls)" do
      let(:response) { build_response(callback_args: callback_args) }

      let(:mock_message) do
        RubyLLM::Message.new(role: :assistant, content: "Hello! How can I help?")
      end

      let(:test_callback_instance) { TestCallback.new }

      before do
        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(mock_message)

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

      it "parses the response using the provider" do
        callback.on_complete(response)

        expect(provider_instance).to have_received(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
      end

      it "calls the user callback with chat, message, callback_args, and response" do
        callback.on_complete(response)

        expect(test_callback_instance).to have_received(:on_complete)
          .with(
            instance_of(PatientHttp::LLM::Chat),
            mock_message,
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

    context "with tool calls and registered tools" do
      let(:tool_call_id) { "call_abc123" }

      let(:tool_calls_hash) do
        {tool_call_id => RubyLLM::ToolCall.new(id: tool_call_id, name: "weather", arguments: {city: "SF"})}
      end

      let(:tool_call_message) do
        RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls_hash)
      end

      let(:chat_data_with_tools) do
        chat_data.merge("tools" => ["WeatherTool"])
      end

      let(:callback_args_with_tools) do
        {
          chat: chat_data_with_tools,
          chat_callback: "TestCallback",
          custom: {"user_id" => "123"}
        }
      end

      let(:response) { build_response(callback_args: callback_args_with_tools) }

      before do
        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(tool_call_message)
      end

      it "executes the tool and re-asks the LLM" do
        allow(provider_instance).to receive(:send)
          .with(:render_payload, anything, anything)
          .and_return({})
        allow(provider_instance).to receive(:api_base).and_return("https://api.openai.com")
        allow(provider_instance).to receive(:headers).and_return({})

        expect(PatientHttp).to receive(:post) do |url, **kwargs|
          expect(url).to include("openai.com")
          expect(kwargs[:callback_args][:tool_iteration]).to eq(1)

          chat_json = kwargs[:callback_args][:chat]
          messages = chat_json["messages"]
          expect(messages.size).to eq(3)
          expect(messages[1]["role"]).to eq("assistant")
          expect(messages[1]["tool_calls"]).to be_a(Hash)
          expect(messages[2]["role"]).to eq("tool")
          expect(messages[2]["content"]).to include("72°F")
          expect(messages[2]["tool_call_id"]).to eq(tool_call_id)
        end

        callback.on_complete(response)
      end

      it "increments tool_iteration across rounds" do
        callback_args_iter = callback_args_with_tools.merge(tool_iteration: 3)
        response_iter = build_response(callback_args: callback_args_iter)

        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(tool_call_message)
        allow(provider_instance).to receive(:send)
          .with(:render_payload, anything, anything)
          .and_return({})
        allow(provider_instance).to receive(:api_base).and_return("https://api.openai.com")
        allow(provider_instance).to receive(:headers).and_return({})

        expect(PatientHttp).to receive(:post) do |_url, **kwargs|
          expect(kwargs[:callback_args][:tool_iteration]).to eq(4)
        end

        callback.on_complete(response_iter)
      end
    end

    context "with a halting tool" do
      let(:tool_call_id) { "call_halt1" }

      let(:tool_calls_hash) do
        {tool_call_id => RubyLLM::ToolCall.new(id: tool_call_id, name: "halting", arguments: {reason: "done"})}
      end

      let(:tool_call_message) do
        RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls_hash)
      end

      let(:chat_data_with_halting_tool) do
        chat_data.merge("tools" => ["HaltingTool"])
      end

      let(:callback_args_with_halting_tool) do
        {
          chat: chat_data_with_halting_tool,
          chat_callback: "TestCallback",
          custom: {"user_id" => "123"}
        }
      end

      let(:response) { build_response(callback_args: callback_args_with_halting_tool) }
      let(:test_callback_instance) { TestCallback.new }

      before do
        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(tool_call_message)

        allow(TestCallback).to receive(:new).and_return(test_callback_instance)
        allow(test_callback_instance).to receive(:on_complete)
      end

      it "stops the tool loop and delivers halt message to user callback" do
        callback.on_complete(response)

        expect(test_callback_instance).to have_received(:on_complete) do |chat, message, _args, _response|
          expect(message).to be_a(RubyLLM::Message)
          expect(message.role).to eq(:assistant)
          expect(message.content).to include("Halted: done")

          expect(chat.messages.size).to eq(3)
          expect(chat.messages[1][:role]).to eq(:assistant)
          expect(chat.messages[2][:role]).to eq(:tool)
        end
      end
    end

    context "with an unknown tool" do
      let(:tool_call_id) { "call_unknown1" }

      let(:tool_calls_hash) do
        {tool_call_id => RubyLLM::ToolCall.new(id: tool_call_id, name: "nonexistent", arguments: {})}
      end

      let(:tool_call_message) do
        RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls_hash)
      end

      let(:chat_data_with_tools) do
        chat_data.merge("tools" => ["WeatherTool"])
      end

      let(:callback_args_with_tools) do
        {
          chat: chat_data_with_tools,
          chat_callback: "TestCallback",
          custom: {"user_id" => "123"}
        }
      end

      let(:response) { build_response(callback_args: callback_args_with_tools) }

      before do
        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(tool_call_message)
        allow(provider_instance).to receive(:send)
          .with(:render_payload, anything, anything)
          .and_return({})
        allow(provider_instance).to receive(:api_base).and_return("https://api.openai.com")
        allow(provider_instance).to receive(:headers).and_return({})
      end

      it "returns an error string as the tool result and continues" do
        expect(PatientHttp).to receive(:post) do |_url, **kwargs|
          chat_json = kwargs[:callback_args][:chat]
          messages = chat_json["messages"]

          tool_result_msg = messages.find { |m| m["role"] == "tool" }
          expect(tool_result_msg["content"]).to include("unavailable tool")
          expect(tool_result_msg["content"]).to include("nonexistent")
        end

        callback.on_complete(response)
      end
    end

    context "with tool iteration limit exceeded" do
      let(:tool_call_id) { "call_limit1" }

      let(:tool_calls_hash) do
        {tool_call_id => RubyLLM::ToolCall.new(id: tool_call_id, name: "weather", arguments: {city: "SF"})}
      end

      let(:tool_call_message) do
        RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls_hash)
      end

      let(:chat_data_with_tools) do
        chat_data.merge("tools" => ["WeatherTool"], "max_tool_iterations" => 3)
      end

      let(:callback_args_at_limit) do
        {
          chat: chat_data_with_tools,
          chat_callback: "TestCallback",
          custom: {"user_id" => "123"},
          tool_iteration: 3
        }
      end

      let(:response) { build_response(callback_args: callback_args_at_limit) }
      let(:test_callback_instance) { TestCallback.new }

      before do
        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(tool_call_message)

        allow(TestCallback).to receive(:new).and_return(test_callback_instance)
        allow(test_callback_instance).to receive(:on_error)
      end

      it "calls on_error with ToolIterationLimitError" do
        callback.on_complete(response)

        expect(test_callback_instance).to have_received(:on_error) do |chat, _args, error|
          expect(chat).to be_a(PatientHttp::LLM::Chat)
          expect(error).to be_a(PatientHttp::LLM::ToolIterationLimitError)
          expect(error.error_type).to eq(:tool_iteration_limit)
          expect(error.message).to include("3")
        end
      end

      it "does not execute the tool" do
        callback.on_complete(response)

        expect(test_callback_instance).to have_received(:on_error)
      end
    end

    context "with tool calls but no registered tools" do
      let(:tool_call_id) { "call_notool1" }

      let(:tool_calls_hash) do
        {tool_call_id => RubyLLM::ToolCall.new(id: tool_call_id, name: "weather", arguments: {city: "SF"})}
      end

      let(:tool_call_message) do
        RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls_hash)
      end

      let(:response) { build_response(callback_args: callback_args) }
      let(:test_callback_instance) { TestCallback.new }

      before do
        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(tool_call_message)

        allow(TestCallback).to receive(:new).and_return(test_callback_instance)
        allow(test_callback_instance).to receive(:on_complete)
      end

      it "passes the tool call message through to user callback without executing" do
        callback.on_complete(response)

        expect(test_callback_instance).to have_received(:on_complete) do |_chat, message, _args, _response|
          expect(message).to eq(tool_call_message)
          expect(message.tool_call?).to be true
        end
      end
    end

    context "with multiple tool calls in one message" do
      let(:tool_call_1_id) { "call_multi1" }
      let(:tool_call_2_id) { "call_multi2" }

      let(:tool_calls_hash) do
        {
          tool_call_1_id => RubyLLM::ToolCall.new(id: tool_call_1_id, name: "weather", arguments: {city: "SF"}),
          tool_call_2_id => RubyLLM::ToolCall.new(id: tool_call_2_id, name: "calculator",
            arguments: {expression: "2+2"})
        }
      end

      let(:tool_call_message) do
        RubyLLM::Message.new(role: :assistant, content: "", tool_calls: tool_calls_hash)
      end

      let(:chat_data_with_tools) do
        chat_data.merge("tools" => %w[WeatherTool CalculatorTool])
      end

      let(:callback_args_with_tools) do
        {
          chat: chat_data_with_tools,
          chat_callback: "TestCallback",
          custom: {"user_id" => "123"}
        }
      end

      let(:response) { build_response(callback_args: callback_args_with_tools) }

      before do
        allow(provider_instance).to receive(:send)
          .with(:parse_completion_response, instance_of(Faraday::Response))
          .and_return(tool_call_message)
        allow(provider_instance).to receive(:send)
          .with(:render_payload, anything, anything)
          .and_return({})
        allow(provider_instance).to receive(:api_base).and_return("https://api.openai.com")
        allow(provider_instance).to receive(:headers).and_return({})
      end

      it "executes all tools and appends all results" do
        expect(PatientHttp).to receive(:post) do |_url, **kwargs|
          chat_json = kwargs[:callback_args][:chat]
          messages = chat_json["messages"]

          expect(messages.size).to eq(4)

          tool_results = messages.select { |m| m["role"] == "tool" }
          expect(tool_results.size).to eq(2)

          weather_result = tool_results.find { |m| m["tool_call_id"] == tool_call_1_id }
          expect(weather_result["content"]).to include("72°F")

          calc_result = tool_results.find { |m| m["tool_call_id"] == tool_call_2_id }
          expect(calc_result["content"]).to include("result")
        end

        callback.on_complete(response)
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

  describe "#to_faraday_response (private)" do
    let(:response) do
      PatientHttp::Response.new(
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate({"choices" => []}),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )
    end

    it "converts async response to Faraday::Response" do
      faraday_response = callback.send(:to_faraday_response, response)

      expect(faraday_response).to be_a(Faraday::Response)
      expect(faraday_response.status).to eq(200)
      expect(faraday_response.body).to eq({"choices" => []})
    end

    it "uses body when response is not JSON" do
      allow(response).to receive(:json?).and_return(false)
      allow(response).to receive(:body).and_return("plain text response")

      faraday_response = callback.send(:to_faraday_response, response)

      expect(faraday_response.body).to eq("plain text response")
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
end
