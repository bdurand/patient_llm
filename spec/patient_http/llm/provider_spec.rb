# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::LLM::Configuration do
  let(:config) { described_class.new }

  describe "#provider" do
    it "registers a provider with url and headers" do
      config.provider :openai, url: "https://api.openai.com", headers: {"Authorization" => "Bearer key"}
      result = config.lookup(:openai)
      expect(result[:url]).to eq("https://api.openai.com")
      expect(result[:headers]).to eq({"Authorization" => "Bearer key"})
    end

    it "defaults headers to empty hash" do
      config.provider :local, url: "http://localhost:1234"
      result = config.lookup(:local)
      expect(result[:headers]).to eq({})
    end

    it "accepts string provider names" do
      config.provider "openai", url: "https://api.openai.com"
      expect(config.lookup(:openai)).not_to be_nil
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

RSpec.describe PatientHttp::LLM do
  describe ".configure" do
    it "yields a Configuration instance" do
      PatientHttp::LLM.configure do |config|
        expect(config).to be_a(PatientHttp::LLM::Configuration)
      end
    end
  end

  describe ".provider" do
    it "looks up a registered provider" do
      result = PatientHttp::LLM.provider(:openai)
      expect(result[:url]).to eq("https://api.openai.com")
    end

    it "returns nil for unregistered providers" do
      expect(PatientHttp::LLM.provider(:nonexistent)).to be_nil
    end
  end
end
