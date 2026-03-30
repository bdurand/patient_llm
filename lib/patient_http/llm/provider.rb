# frozen_string_literal: true

module PatientHttp
  module LLM
    # Configuration for provider registry.
    #
    # @example
    #   PatientHttp::LLM.configure do |config|
    #     config.provider :openai,
    #       url: "https://api.openai.com",
    #       headers: {"Authorization" => "Bearer #{ENV["OPENAI_API_KEY"]}"}
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
      # @return [void]
      def provider(name, url:, headers: {})
        @providers[name.to_sym] = {url: url, headers: headers}
      end

      # Look up a registered provider by name.
      #
      # @param name [Symbol, String] Provider name
      # @return [Hash, nil] Provider config hash with :url and :headers keys
      def lookup(name)
        @providers[name&.to_sym]
      end
    end
  end
end
