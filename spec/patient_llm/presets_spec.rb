# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM::Presets do
  let(:config) { PatientLLM::Configuration.new }

  after do
    PatientHttp.default_configuration = nil
  end

  describe "provider presets" do
    it "expands the anthropic preset to the hand-written configuration" do
      config.provider :anthropic, preset: :anthropic, api_key: -> { "test-key" }

      result = config.lookup(:anthropic)
      expect(result[:url]).to eq("https://api.anthropic.com")
      expect(result[:serializer]).to eq(:messages)
      expect(result[:headers]["x-api-key"]).to eq(PatientHttp.secret("patient_llm.anthropic.api_key"))
      expect(result[:headers]["anthropic-version"]).to eq(PatientLLM::ANTHROPIC_VERSION)
    end

    it "expands the openai preset with a Bearer authorization header" do
      config.provider :openai_preset, preset: :openai, api_key: -> { "test-key" }

      result = config.lookup(:openai_preset)
      expect(result[:url]).to eq("https://api.openai.com")
      expect(result[:serializer]).to eq(:open_responses)
      expect(result[:headers]["authorization"]).to eq(PatientHttp.secret("patient_llm.openai_preset.api_key"))
    end

    it "expands the gemini preset" do
      config.provider :gemini, preset: :gemini, api_key: -> { "test-key" }

      result = config.lookup(:gemini)
      expect(result[:url]).to eq("https://generativelanguage.googleapis.com")
      expect(result[:serializer]).to eq(:gemini)
      expect(result[:headers]["x-goog-api-key"]).to eq(PatientHttp.secret("patient_llm.gemini.api_key"))
    end

    it "fills the bedrock preset URL from the region" do
      config.provider :bedrock, preset: :bedrock_runtime, region: "us-west-2", preprocessors: :aws_sigv4

      result = config.lookup(:bedrock)
      expect(result[:url]).to eq("https://bedrock-runtime.us-west-2.amazonaws.com")
      expect(result[:serializer]).to eq(:converse)
      expect(result[:preprocessors]).to eq(:aws_sigv4)
    end

    it "raises when the bedrock preset is used without a region" do
      expect {
        config.provider :bedrock, preset: :bedrock_runtime
      }.to raise_error(ArgumentError, /region/)
    end

    it "raises for an unknown preset" do
      expect {
        config.provider :mystery, preset: :mystery
      }.to raise_error(ArgumentError, /Unknown preset/)
    end

    it "lets explicit options override preset values" do
      config.provider :proxied, preset: :openai, url: "https://llm-gateway.internal", serializer: :open_responses, api_key: -> { "k" }

      result = config.lookup(:proxied)
      expect(result[:url]).to eq("https://llm-gateway.internal")
      expect(result[:serializer]).to eq(:open_responses)
    end

    it "lets explicit headers override preset headers" do
      config.provider :anthropic_custom, preset: :anthropic, api_key: -> { "k" }, headers: {"anthropic-version" => "2024-01-01"}

      result = config.lookup(:anthropic_custom)
      expect(result[:headers]["anthropic-version"]).to eq("2024-01-01")
    end
  end

  describe "api_key registration" do
    it "registers the key as a PatientHttp secret named after the provider" do
      config.provider :acme, preset: :anthropic, api_key: -> { "acme-key" }

      expect(PatientHttp.secret_registered?("patient_llm.acme.api_key")).to be true
    end

    it "applies the preset's auth format inside the registered secret" do
      config.provider :formatted, preset: :openai, api_key: -> { "raw-key" }

      patient_http_config = PatientHttp::Configuration.new
      PatientHttp.default_configuration = patient_http_config
      expect(patient_http_config.secret_manager.resolve("patient_llm.formatted.api_key")).to eq("Bearer raw-key")
    end

    it "resolves the key lazily at fetch time" do
      value = "initial"
      config.provider :lazy, preset: :anthropic, api_key: -> { value }

      patient_http_config = PatientHttp::Configuration.new
      PatientHttp.default_configuration = patient_http_config
      value = "rotated"
      expect(patient_http_config.secret_manager.resolve("patient_llm.lazy.api_key")).to eq("rotated")
    end

    it "accepts a plain string api_key" do
      config.provider :stringy, preset: :openai, api_key: "string-key"

      patient_http_config = PatientHttp::Configuration.new
      PatientHttp.default_configuration = patient_http_config
      expect(patient_http_config.secret_manager.resolve("patient_llm.stringy.api_key")).to eq("Bearer string-key")
    end

    it "uses an existing SecretReference as-is without registering anything" do
      config.provider :byo, preset: :openai, api_key: PatientHttp.secret("my.own.secret")

      result = config.lookup(:byo)
      expect(result[:headers]["authorization"]).to eq(PatientHttp.secret("my.own.secret"))
      expect(PatientHttp.secret_registered?("patient_llm.byo.api_key")).to be false
    end

    it "raises when api_key is given without a preset auth header" do
      expect {
        config.provider :headerless, url: "https://example.com", api_key: -> { "k" }
      }.to raise_error(ArgumentError, /preset that defines an authentication header/)
    end

    it "raises for an unsupported api_key type" do
      expect {
        config.provider :weird, preset: :openai, api_key: 12345
      }.to raise_error(ArgumentError, /api_key must be/)
    end
  end

  describe "provider options" do
    it "stores timeout and max_tool_iterations" do
      config.provider :tuned, url: "https://example.com", timeout: 300, max_tool_iterations: 25

      result = config.lookup(:tuned)
      expect(result[:timeout]).to eq(300)
      expect(result[:max_tool_iterations]).to eq(25)
    end

    it "requires a url when no preset supplies one" do
      expect {
        config.provider :missing
      }.to raise_error(ArgumentError, /url is required/)
    end
  end
end

RSpec.describe "PatientLLM.verify_configuration!" do
  after do
    PatientHttp.default_configuration = nil
    PatientLLM.reset!
    PatientLLM.configure do |c|
      c.provider :openai,
        url: "https://api.openai.com",
        headers: {"Authorization" => PatientHttp.secret("openai.api_key")},
        serializer: :chat_completion
    end
  end

  def with_fake_handler
    PatientHttp.register_handler(->(request:, callback:, callback_args:, raise_error_responses:) { "id" })
    yield
  ensure
    PatientHttp.unregister_handler
  end

  it "raises when no request handler is registered" do
    expect {
      PatientLLM.verify_configuration!
    }.to raise_error(/No PatientHttp request handler is registered/)
  end

  it "raises when a provider references an unregistered secret" do
    PatientLLM.reset!
    PatientLLM.configure do |c|
      c.provider :phantom, url: "https://example.com", headers: {"x-api-key" => PatientHttp.secret("never.registered")}
    end

    with_fake_handler do
      expect {
        PatientLLM.verify_configuration!
      }.to raise_error(/references secret "never.registered"/)
    end
  end

  it "raises when a provider references an unregistered preprocessor" do
    PatientLLM.reset!
    PatientLLM.configure do |c|
      c.provider :signed, url: "https://example.com", preprocessors: :missing_signer
    end
    PatientHttp.default_configuration = PatientHttp::Configuration.new

    with_fake_handler do
      expect {
        PatientLLM.verify_configuration!
      }.to raise_error(/references preprocessor :missing_signer/)
    end
  end

  it "returns true when everything is wired" do
    PatientLLM.reset!
    PatientLLM.configure do |c|
      c.provider :wired, preset: :anthropic, api_key: -> { "key" }
    end

    with_fake_handler do
      expect(PatientLLM.verify_configuration!).to be true
    end
  end
end
