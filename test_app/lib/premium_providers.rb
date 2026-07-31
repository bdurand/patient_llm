# frozen_string_literal: true

# UI metadata for the premium providers exposed by the test app. All of the
# vendor plumbing (URLs, serializers, auth headers, key formats, endpoint
# paths) comes from the PatientLLM presets; this table only holds what the
# test app UI needs.
module PremiumProviders
  PROVIDERS = {
    "openai" => {label: "OpenAI", env_key: "OPENAI_API_KEY", default_model: "gpt-5.4-nano"},
    "anthropic" => {label: "Anthropic", env_key: "ANTHROPIC_API_KEY", default_model: "claude-haiku-4-5"},
    "gemini" => {label: "Gemini", env_key: "GEMINI_API_KEY", default_model: "gemini-3.1-flash-lite"},
    "bedrock" => {label: "Bedrock", env_key: "BEDROCK_API_KEY", default_model: "moonshotai.kimi-k2.5"}
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

    # The serializer for a registered provider, from the PatientLLM registry.
    #
    # @param provider_name [String] the provider identifier
    # @return [Symbol, nil] the serializer name
    def serializer(provider_name)
      PatientLLM.provider(provider_name)&.dig(:serializer)
    end

    # A lambda that resolves the provider's API key from the environment.
    #
    # @param provider_name [String] the provider identifier
    # @return [Proc] the API key resolver
    def api_key(provider_name)
      env_key = PROVIDERS.fetch(provider_name).fetch(:env_key)
      -> { ENV.fetch(env_key) }
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

    # True when the environment suggests AWS credentials may be configured.
    #
    # @return [Boolean]
    def aws_credentials_hinted?
      return true if ENV["AWS_ACCESS_KEY_ID"] || ENV["AWS_PROFILE"]

      File.exist?(File.expand_path("~/.aws/credentials")) || File.exist?(File.expand_path("~/.aws/config"))
    end
  end
end
