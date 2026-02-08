# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncLLM::Callback do
  let(:callback) { described_class.new }

  let(:chat_data) do
    {
      "v" => 1,
      "callback" => "TestCallback",
      "model" => "gpt-4",
      "provider" => "openai",
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
    let(:response) do
      AsyncHttpPool::Response.new(
        callback_args: callback_args,
        http_method: :post,
        url: "https://api.openai.com/v1/chat/completions",
        status: 200,
        headers: {"content-type" => "application/json"},
        body: JSON.generate({
          "choices" => [
            {"message" => {"role" => "assistant", "content" => "Hello! How can I help?"}}
          ],
          "usage" => {"prompt_tokens" => 10, "completion_tokens" => 8}
        }),
        duration: 1.0,
        request_id: SecureRandom.uuid
      )
    end

    let(:mock_message) do
      instance_double(RubyLLM::Message, role: :assistant, content: "Hello! How can I help?")
    end

    let(:provider_instance) do
      instance_double("RubyLLM::Providers::OpenAI")
    end

    let(:test_callback_instance) { TestCallback.new }

    before do
      allow(RubyLLM::Models).to receive(:resolve)
        .with("gpt-4", provider: "openai", assume_exists: true)
        .and_return([double("model"), provider_instance])

      allow(provider_instance).to receive(:send)
        .with(:parse_completion_response, instance_of(Faraday::Response))
        .and_return(mock_message)

      allow(TestCallback).to receive(:new).and_return(test_callback_instance)
      allow(test_callback_instance).to receive(:on_complete)
    end

    it "loads the chat from callback_args" do
      callback.on_complete(response)

      expect(test_callback_instance).to have_received(:on_complete) do |chat, _message, _args, _response|
        expect(chat).to be_a(Sidekiq::AsyncLLM::Chat)
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
          instance_of(Sidekiq::AsyncLLM::Chat),
          mock_message,
          instance_of(AsyncHttpPool::CallbackArgs),
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
        AsyncHttpPool::Error,
        callback_args: callback_args,
        error_type: :http_error,
        message: "Connection failed"
      )
    end

    let(:test_callback_instance) { TestCallback.new }

    before do
      allow(AsyncHttpPool::ClassHelper).to receive(:resolve_class_name)
        .with("TestCallback")
        .and_return(TestCallback)

      allow(TestCallback).to receive(:new).and_return(test_callback_instance)
      allow(test_callback_instance).to receive(:on_error)
    end

    it "loads the chat from callback_args" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error) do |chat, _args, _error|
        expect(chat).to be_a(Sidekiq::AsyncLLM::Chat)
        expect(chat.model).to eq("gpt-4")
      end
    end

    it "calls the user callback with chat, callback_args, and error" do
      callback.on_error(error)

      expect(test_callback_instance).to have_received(:on_error)
        .with(
          instance_of(Sidekiq::AsyncLLM::Chat),
          instance_of(AsyncHttpPool::CallbackArgs),
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
      AsyncHttpPool::Response.new(
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

      expect(args).to be_a(AsyncHttpPool::CallbackArgs)
      expect(args[:user_id]).to eq("123")
      expect(args[:session_id]).to eq("abc")
    end
  end
end
