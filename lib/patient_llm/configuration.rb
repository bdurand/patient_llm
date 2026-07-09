# frozen_string_literal: true

module PatientLLM
  # Headers that must be setup to use the secrets manager. If any of these headers
  # are included in the provider configuration, an error will be raised unless their
  # values are set up as secrets using `PatientHttp.secret`.
  AUTHENTICATION_HEADERS = ["authorization", "x-api-key", "x-goog-api-key", "api-key"].freeze

  # Configuration for provider registry.
  #
  # @example
  #   PatientLLM.configure do |config|
  #     config.provider :openai,
  #       url: "https://api.openai.com",
  #       headers: {"Authorization" => "Bearer #{ENV["OPENAI_API_KEY"]}"},
  #       serializer: :chat_completion
  #   end
  class Configuration
    def initialize
      @providers = {}
    end

    # Register a provider with a base URL and default headers.
    #
    # @param name [Symbol, String] Provider name
    # @param url [String] Base URL for the provider API
    # @param headers [Hash] Default headers for requests
    # @param serializer [Symbol] API format (:chat_completion, :open_responses, :messages, :converse, :gemini)
    # @param path [String, nil] Override the default endpoint path
    # @param completion_path [String, nil] Deprecated alias for +path+
    # @param params [Hash] Additional parameters to merge into every request payload
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] Names of request
    #   preprocessors to apply to every request (e.g. for request signing). Names must be
    #   registered on the PatientHttp configuration with `register_preprocessor`.
    # @return [void]
    def provider(name, url:, headers: {}, serializer: :chat_completion, path: nil, completion_path: nil, params: {}, preprocessors: nil)
      if completion_path
        warn "PatientLLM::Configuration#provider: the `completion_path:` argument is deprecated; use `path:` instead", uplevel: 1
        path ||= completion_path
      end

      sym = serializer.to_sym
      unless PatientLLM::VALID_SERIALIZERS.include?(sym)
        raise ArgumentError, "Unknown serializer: #{sym.inspect}. Valid options: #{PatientLLM::VALID_SERIALIZERS.map(&:inspect).join(", ")}"
      end

      ensure_auth_headers_use_secrets!(headers)

      @providers[name.to_s] = {
        url: url,
        headers: headers,
        serializer: sym,
        path: path,
        params: params,
        preprocessors: preprocessors
      }
    end

    # Look up a registered provider by name.
    #
    # @param name [Symbol, String] Provider name
    # @return [Hash, nil] Provider config hash
    def lookup(name)
      @providers[name&.to_s]
    end

    private

    def ensure_auth_headers_use_secrets!(headers)
      headers.each do |header_name, header_value|
        normalized_header_name = header_name.to_s.downcase
        next unless AUTHENTICATION_HEADERS.include?(normalized_header_name)

        if header_value && !header_value.is_a?(PatientHttp::SecretReference)
          raise ArgumentError, "Authentication header #{header_name} must be set up as a secret using `PatientHttp.secret`"
        end
      end
    end
  end
end
