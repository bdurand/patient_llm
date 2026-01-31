# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sidekiq::AsyncLLM::Middleware do
  let(:middleware) { described_class.new }
  let(:worker) { TestCompletionWorker.new }
  let(:queue) { "default" }

  let(:chat_data) do
    {
      "v" => 1,
      "completion_worker" => "TestCompletionWorker",
      "error_worker" => "TestErrorWorker",
      "model" => "gpt-4",
      "provider" => "openai",
      "api_base" => nil,
      "messages" => [{"role" => "user", "content" => "Hello"}],
      "temperature" => nil,
      "thinking" => nil,
      "schema" => nil,
      "params" => {},
      "headers" => {}
    }
  end

  describe "#call" do
    context "with a completion response" do
      let(:response_body) do
        {
          "id" => "chatcmpl-123",
          "object" => "chat.completion",
          "model" => "gpt-4",
          "choices" => [
            {
              "index" => 0,
              "message" => {
                "role" => "assistant",
                "content" => "Hello! How can I help you?"
              },
              "finish_reason" => "stop"
            }
          ],
          "usage" => {
            "prompt_tokens" => 10,
            "completion_tokens" => 8,
            "total_tokens" => 18
          }
        }
      end

      let(:response) do
        Sidekiq::AsyncHttp::Response.new(
          status: 200,
          headers: {"content-type" => "application/json"},
          body: response_body.to_json,
          duration: 1.5,
          request_id: "test-123",
          url: "https://api.openai.com/v1/chat/completions",
          http_method: :post,
          callback_args: {
            "chat" => chat_data,
            "provider" => "openai",
            "model" => "gpt-4"
          }
        )
      end

      let(:job) do
        {
          "class" => "TestCompletionWorker",
          "args" => [response]
        }
      end

      it "transforms job args to [response, chat, message]" do
        yielded = false
        middleware.call(worker, job, queue) { yielded = true }

        expect(yielded).to be true
        expect(job["args"].length).to eq(3)

        response_arg, chat, message = job["args"]
        expect(response_arg).to eq(response)
        expect(chat).to be_a(Sidekiq::AsyncLLM::Chat)
        expect(chat.model).to eq("gpt-4")
        expect(message).to be_a(RubyLLM::Message)
        expect(message.role).to eq(:assistant)
        expect(message.content).to eq("Hello! How can I help you?")
      end
    end

    context "with an error response" do
      let(:error) do
        Sidekiq::AsyncHttp::RequestError.new(
          class_name: "Async::TimeoutError",
          message: "Request timed out after 60 seconds",
          backtrace: [],
          error_type: :timeout,
          duration: 60.0,
          request_id: "test-123",
          url: "https://api.openai.com/v1/chat/completions",
          http_method: :post,
          callback_args: {
            "chat" => chat_data,
            "provider" => "openai",
            "model" => "gpt-4"
          }
        )
      end

      let(:job) do
        {
          "class" => "TestErrorWorker",
          "args" => [error]
        }
      end

      it "transforms job args to [error, chat]" do
        yielded = false
        middleware.call(worker, job, queue) { yielded = true }

        expect(yielded).to be true
        expect(job["args"].length).to eq(2)

        error_arg, chat = job["args"]
        expect(chat).to be_a(Sidekiq::AsyncLLM::Chat)
        expect(error_arg).to eq(error)
      end
    end

    context "with a non-async-llm job" do
      let(:job) do
        {
          "class" => "SomeOtherWorker",
          "args" => ["regular", "args"]
        }
      end

      it "passes through unchanged" do
        original_args = job["args"].dup
        yielded = false
        middleware.call(worker, job, queue) { yielded = true }

        expect(yielded).to be true
        expect(job["args"]).to eq(original_args)
      end
    end

    context "with a response without chat data" do
      let(:response) do
        Sidekiq::AsyncHttp::Response.new(
          status: 200,
          headers: {"content-type" => "application/json"},
          body: "{}",
          duration: 1.0,
          request_id: "test-123",
          url: "https://example.com",
          http_method: :get,
          callback_args: {"other_key" => "value"}
        )
      end

      let(:job) do
        {
          "class" => "TestCompletionWorker",
          "args" => [response]
        }
      end

      it "passes through unchanged" do
        original_args = job["args"].dup
        yielded = false
        middleware.call(worker, job, queue) { yielded = true }

        expect(yielded).to be true
        expect(job["args"]).to eq(original_args)
      end
    end
  end
end
