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
    # Bedrock is also available without an API key when AWS credentials resolve,
    # in which case requests are SigV4 signed.
    #
    # @return [Hash] provider configs keyed by provider name
    def available
      PROVIDERS.select do |name, config|
        key = ENV[config[:env_key]]
        (key && !key.empty?) || (name == "bedrock" && bedrock_sigv4?)
      end
    end

    # True when the AWS default credential chain resolves. When true, Bedrock
    # requests are SigV4 signed instead of using the BEDROCK_API_KEY bearer token.
    # The chain is only consulted when env vars or ~/.aws files suggest credentials
    # are configured, to avoid the slow EC2 instance metadata probe on machines
    # with no AWS setup.
    #
    # @return [Boolean]
    def bedrock_sigv4?
      return @bedrock_sigv4 if defined?(@bedrock_sigv4)
      @bedrock_sigv4 = begin
        if aws_credentials_hinted?
          !Aws::CredentialProviderChain.new.resolve.nil?
        else
          false
        end
      rescue
        false
      end
    end

    # Returns the preprocessor names for a provider, or nil.
    #
    # @param provider_name [String] the provider identifier
    # @return [Symbol, nil] the preprocessor name
    def preprocessors(provider_name)
      :aws_sigv4 if provider_name.to_s == "bedrock" && bedrock_sigv4?
    end

    # Returns the auth headers for a given provider. SigV4 signing sets the
    # Authorization header itself, so bedrock gets no bearer header in that mode.
    #
    # @param provider_name [String] the provider identifier
    # @return [Hash] headers hash with the appropriate auth key and secret
    def auth_header(provider_name)
      return {} if provider_name == "bedrock" && bedrock_sigv4?

      secret_name = "#{provider_name}.api_key"
      secret_value = PatientHttp.secret(secret_name)
      case provider_name
      when "anthropic"
        {"x-api-key" => secret_value}
      when "gemini"
        {"x-goog-api-key" => secret_value}
      else
        {"authorization" => secret_value}
      end
    end

    # Returns the formatted auth header value for a provider.
    #
    # @param provider_name [String] the provider identifier
    # @return [String, nil] the formatted header value
    def auth_header_value(provider_name)
      return nil if provider_name == "bedrock" && bedrock_sigv4?

      config = PROVIDERS[provider_name]
      return nil unless config

      value = ENV[config[:env_key]]
      return nil if value.nil? || value.empty?

      case provider_name
      when "anthropic"
        value
      when "gemini"
        value
      else
        "Bearer #{value}"
      end
    end

    # Returns the endpoint path for a provider, substituting the model name where needed.
    #
    # @param provider_name [String] the provider identifier
    # @param model [String] the model name
    # @return [String, nil] the endpoint path or nil for default
    def path(provider_name, model)
      case provider_name
      when "gemini"
        "/v1beta/models/#{model}:generateContent"
      when "bedrock"
        "/model/#{model}/converse"
      end
    end

    # True when the environment suggests AWS credentials may be configured.
    #
    # @return [Boolean]
    def aws_credentials_hinted?
      return true if ENV["AWS_ACCESS_KEY_ID"] || ENV["AWS_PROFILE"]

      File.exist?(File.expand_path("~/.aws/credentials")) || File.exist?(File.expand_path("~/.aws/config"))
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
