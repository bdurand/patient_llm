# frozen_string_literal: true

module PatientHttp
  module LLM
    # Configuration for provider registry.
    #
    # @example
    #   PatientHttp::LLM.configure do |config|
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
      # @param serializer [Symbol] API format (:chat_completion, :open_responses, :messages)
      # @param completion_path [String, nil] Override the default endpoint path
      # @param params [Hash] Additional parameters to merge into every request payload
      # @return [void]
      def provider(name, url:, headers: {}, serializer: :chat_completion, completion_path: nil, params: {})
        sym = serializer.to_sym
        unless PatientHttp::LLM::VALID_SERIALIZERS.include?(sym)
          raise ArgumentError, "Unknown serializer: #{sym.inspect}. Valid options: #{PatientHttp::LLM::VALID_SERIALIZERS.map(&:inspect).join(", ")}"
        end

        @providers[name.to_sym] = {
          url: url,
          headers: headers,
          serializer: sym,
          completion_path: completion_path,
          params: params
        }
      end

      # Look up a registered provider by name.
      #
      # @param name [Symbol, String] Provider name
      # @return [Hash, nil] Provider config hash
      def lookup(name)
        @providers[name&.to_sym]
      end
    end
  end
end
