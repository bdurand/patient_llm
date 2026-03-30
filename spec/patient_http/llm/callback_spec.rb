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
end
