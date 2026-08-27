# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM, ".preview_request" do
  let(:session) do
    PromptBuilder::Session.new(model: "gpt-4", max_output_tokens: 1000).tap { |s| s.user("Hello") }
  end

  def with_fake_handler
    captured = nil
    fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
      captured = {request: request, callback: callback, callback_args: callback_args, raise_error_responses: raise_error_responses}
      "req-id"
    }

    PatientHttp.register_handler(fake_handler)
    begin
      yield -> { captured }
    ensure
      PatientHttp.unregister_handler
    end
  end

  describe "parity with ask" do
    it "returns the same url, payload, and headers that ask sends" do
      options = {
        provider: :openai,
        serializer: :messages,
        headers: {"x-test" => "1"},
        params: {"metadata" => {"user_id" => "u1"}}
      }

      with_fake_handler do |captured|
        PatientLLM.ask(session, callback: "TestCallback", **options)
        preview = PatientLLM.preview_request(session, **options)

        request = captured.call[:request]
        expect(preview.url).to eq(request.url.to_s)
        expect(JSON.generate(preview.payload)).to eq(request.body)
        expect(preview.headers["x-test"]).to eq("1")
        expect(preview.headers["anthropic-version"]).to eq(PatientLLM::ANTHROPIC_VERSION)
        expect(request.headers["anthropic-version"]).to eq(PatientLLM::ANTHROPIC_VERSION)
      end
    end
  end

  describe "request resolution" do
    it "uses the provider's serializer, path, and url by default" do
      preview = PatientLLM.preview_request(session, provider: :openai)

      expect(preview.url).to eq("https://api.openai.com/v1/chat/completions")
      expect(preview.payload["model"]).to eq("gpt-4")
      expect(preview.payload["messages"]).to be_an(Array)
    end

    it "substitutes the model into a {model} path placeholder as a single path segment" do
      preview = PatientLLM.preview_request(session, provider: :openai, serializer: :converse, url: "https://bedrock.example.com")

      expect(preview.url).to eq("https://bedrock.example.com/model/gpt-4/converse")
    end

    it "percent-encodes the model in the path" do
      arn_session = PromptBuilder::Session.new(model: "arn:aws:bedrock:us-east-1::model/claude").tap { |s| s.user("Hello") }
      preview = PatientLLM.preview_request(arn_session, provider: :openai, serializer: :converse, url: "https://bedrock.example.com")

      expect(preview.url).to eq("https://bedrock.example.com/model/#{URI.encode_uri_component(arn_session.model)}/converse")
    end

    it "adds the default anthropic-version header for the messages serializer" do
      preview = PatientLLM.preview_request(session, provider: :openai, serializer: :messages)

      expect(preview.headers["anthropic-version"]).to eq(PatientLLM::ANTHROPIC_VERSION)
    end

    it "does not override an explicit anthropic-version header" do
      preview = PatientLLM.preview_request(session, provider: :openai, serializer: :messages, headers: {"anthropic-version" => "2024-01-01"})

      expect(preview.headers["anthropic-version"]).to eq("2024-01-01")
    end

    it "deep merges params into the payload" do
      preview = PatientLLM.preview_request(session, provider: :openai, params: {metadata: {user_id: "u1"}})

      expect(preview.payload["metadata"]).to eq({"user_id" => "u1"})
      expect(preview.payload["model"]).to eq("gpt-4")
    end

    it "accepts a processor option for parity with ask" do
      preview = PatientLLM.preview_request(session, provider: :openai, processor: :llm)

      expect(preview.url).to eq("https://api.openai.com/v1/chat/completions")
    end
  end

  describe "error parity with ask" do
    it "raises when no url is configured" do
      expect {
        PatientLLM.preview_request(session, provider: :not_registered)
      }.to raise_error(ArgumentError, /No API base URL configured/)
    end

    it "raises for an unknown serializer" do
      expect {
        PatientLLM.preview_request(session, provider: :openai, serializer: :bogus)
      }.to raise_error(ArgumentError, /Unknown serializer/)
    end

    it "raises when the path has a {model} placeholder but the session has no model" do
      modelless = PromptBuilder::Session.new.tap { |s| s.user("Hello") }

      expect {
        PatientLLM.preview_request(modelless, provider: :openai, serializer: :converse)
      }.to raise_error(ArgumentError, /\{model\} placeholder/)
    end
  end

  describe "secret redaction" do
    it "replaces secret reference header values with placeholders" do
      preview = PatientLLM.preview_request(session, provider: :openai)

      expect(preview.headers["Authorization"]).to eq("<secret:openai.api_key>")
    end
  end

  describe "side effects" do
    it "does not enqueue or execute a request" do
      with_fake_handler do |captured|
        PatientLLM.preview_request(session, provider: :openai)

        expect(captured.call).to be_nil
      end
    end

    it "does not write the session to a payload store when session offload is configured" do
      store_class = Class.new(PatientHttp::PayloadStore::Base) do
        def initialize(**)
          @data = {}
        end

        attr_reader :data

        def store(key, data)
          @data[key] = JSON.generate(data)
          key
        end

        def fetch(key)
          json = @data[key]
          json && JSON.parse(json)
        end

        def delete(key)
          @data.delete(key)
          true
        end
      end
      stub_const("TestPreviewMemoryStore", store_class)
      PatientHttp::PayloadStore::Base.register(:test_preview_memory, TestPreviewMemoryStore)

      patient_http_config = PatientHttp::Configuration.new
      patient_http_config.register_payload_store(:session_store, adapter: :test_preview_memory)
      PatientHttp.default_configuration = patient_http_config
      PatientLLM.configure do |c|
        c.session_offload payload_store: :session_store, threshold: 1
      end

      begin
        PatientLLM.preview_request(session, provider: :openai)

        store = patient_http_config.payload_store(:session_store)
        expect(store.data).to be_empty
      ensure
        PatientHttp.default_configuration = nil
        PatientLLM.reset!
        PatientLLM.configure do |c|
          c.provider :openai,
            url: "https://api.openai.com",
            headers: {"Authorization" => PatientHttp.secret("openai.api_key")},
            serializer: :chat_completion
        end
      end
    end
  end
end
