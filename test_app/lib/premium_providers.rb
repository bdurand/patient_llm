# frozen_string_literal: true

module PremiumProviders
  PROVIDERS = {
    "openai" => {
      label: "OpenAI",
      env_key: "OPENAI_API_KEY",
      url: "https://api.openai.com",
      default_model: "gpt-5.4-nano",
      serializer: :open_responses
    },
    "anthropic" => {
      label: "Anthropic",
      env_key: "ANTHROPIC_API_KEY",
      url: "https://api.anthropic.com",
      default_model: "claude-haiku-4-5",
      serializer: :messages
    },
    "gemini" => {
      label: "Gemini",
      env_key: "GEMINI_API_KEY",
      url: "https://generativelanguage.googleapis.com",
      default_model: "gemini-3.1-flash-lite",
      serializer: :gemini
    },
    "bedrock" => {
      label: "Bedrock",
      env_key: "BEDROCK_API_KEY",
      url: "https://bedrock-runtime.%{region}.amazonaws.com",
      default_model: "moonshotai.kimi-k2.5",
      serializer: :converse
    }
  }.freeze

  class << self
    # Returns a hash of available premium providers filtered by env var existence.
    #
    # @return [Hash] provider configs keyed by provider name
    def available
      PROVIDERS.select { |_, config| ENV[config[:env_key]] && !ENV[config[:env_key]].empty? }
    end

    # Returns the auth headers for a given provider.
    #
    # @param provider_name [String] the provider identifier
    # @param api_key [String] the API key
    # @return [Hash] headers hash
    def auth_headers(provider_name, api_key)
      case provider_name
      when "anthropic"
        {"x-api-key" => api_key}
      when "gemini"
        {"x-goog-api-key" => api_key}
      else
        {"Authorization" => "Bearer #{api_key}"}
      end
    end

    # Returns the completion path for a provider, substituting the model name where needed.
    #
    # @param provider_name [String] the provider identifier
    # @param model [String] the model name
    # @return [String, nil] the completion path or nil for default
    def completion_path(provider_name, model)
      case provider_name
      when "gemini"
        "/v1beta/models/#{model}:generateContent"
      when "bedrock"
        "/model/#{model}/converse"
      end
    end

    # Returns the resolved base URL for a provider.
    #
    # @param provider_name [String] the provider identifier
    # @return [String] the base URL
    def base_url(provider_name)
      config = PROVIDERS[provider_name]
      return unless config

      if provider_name == "bedrock"
        region = ENV.fetch("BEDROCK_REGION", "us-east-1")
        format(config[:url], region: region)
      else
        config[:url]
      end
    end
  end
end
