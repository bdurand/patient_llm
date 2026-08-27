# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM::Configuration do
  let(:config) { described_class.new }

  describe "#processor" do
    it "defaults to nil" do
      expect(config.processor).to be_nil
    end

    it "stores an assigned value" do
      config.processor = :llm
      expect(config.processor).to eq(:llm)
    end
  end

  describe "#provider" do
    it "registers a provider with url and headers" do
      config.provider :openai, url: "https://api.openai.com", headers: {"Authorization" => PatientHttp.secret("bearer_token")}
      result = config.lookup(:openai)
      expect(result[:url]).to eq("https://api.openai.com")
      expect(result[:headers]).to eq({"Authorization" => PatientHttp.secret("bearer_token")})
    end

    it "defaults headers to empty hash" do
      config.provider :local, url: "http://localhost:1234"
      result = config.lookup(:local)
      expect(result[:headers]).to eq({})
    end

    it "defaults serializer to :chat_completion" do
      config.provider :local, url: "http://localhost:1234"
      result = config.lookup(:local)
      expect(result[:serializer]).to eq(:chat_completion)
    end

    it "accepts a custom serializer" do
      config.provider :anthropic, url: "https://api.anthropic.com", serializer: :messages
      result = config.lookup(:anthropic)
      expect(result[:serializer]).to eq(:messages)
    end

    it "accepts a path override" do
      config.provider :custom, url: "http://localhost:1234", path: "/api/chat"
      result = config.lookup(:custom)
      expect(result[:path]).to eq("/api/chat")
    end

    it "defaults path to nil" do
      config.provider :local, url: "http://localhost:1234"
      result = config.lookup(:local)
      expect(result[:path]).to be_nil
    end

    it "does not accept the removed completion_path argument" do
      expect {
        config.provider :custom, url: "http://localhost:1234", completion_path: "/api/chat"
      }.to raise_error(ArgumentError)
    end

    it "accepts additional params" do
      config.provider :openai, url: "https://api.openai.com", params: {stream: false}
      result = config.lookup(:openai)
      expect(result[:params]).to eq({stream: false})
    end

    it "raises for an invalid serializer" do
      expect {
        config.provider :bad, url: "http://localhost", serializer: :invalid
      }.to raise_error(ArgumentError, /Unknown serializer.*:invalid/)
    end

    it "defaults params to empty hash" do
      config.provider :local, url: "http://localhost:1234"
      result = config.lookup(:local)
      expect(result[:params]).to eq({})
    end

    it "accepts string provider names" do
      config.provider "openai", url: "https://api.openai.com"
      expect(config.lookup(:openai)).not_to be_nil
    end

    it "accepts preprocessors" do
      config.provider :signed, url: "https://example.com", preprocessors: :aws_sigv4
      result = config.lookup(:signed)
      expect(result[:preprocessors]).to eq(:aws_sigv4)
    end

    it "defaults preprocessors to nil" do
      config.provider :local, url: "http://localhost:1234"
      result = config.lookup(:local)
      expect(result[:preprocessors]).to be_nil
    end

    it "resolves callable arguments each time the provider is looked up" do
      base_url = "https://api.openai.com"
      config.provider :dynamic, url: -> { base_url }, timeout: -> { 30 }

      result = config.lookup(:dynamic)
      expect(result[:url]).to eq("https://api.openai.com")
      expect(result[:timeout]).to eq(30)

      base_url = "https://proxy.example.com"
      expect(config.lookup(:dynamic)[:url]).to eq("https://proxy.example.com")
    end

    it "validates an unknown preset at registration even when another option is callable" do
      expect {
        config.provider :bad, preset: :nope, url: -> { "http://localhost" }
      }.to raise_error(ArgumentError, /Unknown preset/)
    end

    it "resolves a callable region against the preset URL at lookup time" do
      region = "us-east-1"
      config.provider :bedrock, preset: :bedrock_runtime, region: -> { region }

      expect(config.lookup(:bedrock)[:url]).to eq("https://bedrock-runtime.us-east-1.amazonaws.com")
      region = "eu-west-1"
      expect(config.lookup(:bedrock)[:url]).to eq("https://bedrock-runtime.eu-west-1.amazonaws.com")
    end

    it "validates a callable serializer at lookup time rather than registration" do
      config.provider :dynamic, url: "http://localhost", serializer: -> { :invalid }

      expect {
        config.lookup(:dynamic)
      }.to raise_error(ArgumentError, /Unknown serializer.*:invalid/)
    end

    it "validates callable headers at lookup time rather than registration" do
      config.provider :dynamic, url: "http://localhost", headers: -> { {"authorization" => "plain_text_value"} }

      expect {
        config.lookup(:dynamic)
      }.to raise_error(ArgumentError, /Authentication header authorization must be set up as a secret/)
    end

    it "registers the api_key secret at registration time alongside callable arguments" do
      config.provider :dynamic, preset: :openai, api_key: -> { "secret-key" }, url: -> { "https://proxy.example.com" }

      expect(PatientHttp.secret_registered?("patient_llm.dynamic.api_key")).to be(true)

      result = config.lookup(:dynamic)
      expect(result[:url]).to eq("https://proxy.example.com")
      expect(result[:headers]["authorization"]).to be_a(PatientHttp::SecretReference)
    end
  end

  describe "#lookup" do
    it "returns nil for unregistered providers" do
      expect(config.lookup(:nonexistent)).to be_nil
    end

    it "returns nil for nil name" do
      expect(config.lookup(nil)).to be_nil
    end
  end
end

RSpec.describe PatientLLM do
  describe ".configure" do
    it "yields a Configuration instance" do
      PatientLLM.configure do |config|
        expect(config).to be_a(PatientLLM::Configuration)
      end
    end
  end

  describe ".provider" do
    it "looks up a registered provider" do
      result = PatientLLM.provider(:openai)
      expect(result[:url]).to eq("https://api.openai.com")
    end

    it "returns nil for unregistered providers" do
      expect(PatientLLM.provider(:nonexistent)).to be_nil
    end
  end

  describe ".reset!" do
    after do
      PatientLLM.configure do |c|
        c.provider :openai,
          url: "https://api.openai.com",
          headers: {"Authorization" => PatientHttp.secret("openai.api_key")},
          serializer: :chat_completion
      end
    end

    it "clears all providers" do
      PatientLLM.configure { |c| c.provider :temp, url: "http://temp" }
      expect(PatientLLM.provider(:temp)).not_to be_nil

      PatientLLM.reset!
      expect(PatientLLM.provider(:temp)).to be_nil

      # Provider re-registration for other specs is handled by the `after` hook above.
    end
  end

  describe "authentication headers enforcement" do
    it "raises an error setting an unencrypted authentication header" do
      ["authorization", "x-api-key", "x-goog-api-key", "api-key"].each do |header|
        expect {
          PatientLLM.configure do |config|
            config.provider :bad_provider, url: "http://localhost", headers: {header => "plain_text_value"}
          end
        }.to raise_error(ArgumentError, /Authentication header #{header} must be set up as a secret/)
      end
    end
  end

  describe ".ask" do
    let(:session) do
      PromptBuilder::Session.new(model: "claude-sonnet-4-20250514", max_output_tokens: 1000).tap { |s| s.user("Hello") }
    end

    it "includes the anthropic-version header when using the messages serializer" do
      captured = nil
      fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
        captured = request
        "req-id"
      }

      PatientHttp.register_handler(fake_handler)
      begin
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :messages)
        expect(captured.headers["anthropic-version"]).to eq("2023-06-01")
      ensure
        PatientHttp.unregister_handler
      end
    end

    it "does not override a user-supplied anthropic-version header" do
      captured = nil
      fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
        captured = request
        "req-id"
      }

      PatientHttp.register_handler(fake_handler)
      begin
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :messages, headers: {"anthropic-version" => "2024-01-01"})
        expect(captured.headers["anthropic-version"]).to eq("2024-01-01")
      ensure
        PatientHttp.unregister_handler
      end
    end

    it "raises for an invalid serializer override" do
      expect {
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :invalid)
      }.to raise_error(ArgumentError, /Unknown serializer.*:invalid/)
    end

    it "does not include the anthropic-version header for other serializers" do
      captured = nil
      fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
        captured = request
        "req-id"
      }

      PatientHttp.register_handler(fake_handler)
      begin
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.headers["anthropic-version"]).to be_nil
      ensure
        PatientHttp.unregister_handler
      end
    end
  end
end
