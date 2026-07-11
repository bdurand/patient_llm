# frozen_string_literal: true

module PatientLLM
  # Built-in provider presets bundling the vendor-specific details needed to
  # talk to the major LLM APIs: base URL, serializer format, authentication
  # header name, and how the API key is formatted into that header.
  #
  # Presets are pure defaults. Every value can be overridden with the normal
  # keyword arguments to {Configuration#provider}, so a stale preset never
  # blocks anyone.
  #
  # @example
  #   PatientLLM.configure do |config|
  #     config.provider :anthropic, preset: :anthropic, api_key: -> { ENV["ANTHROPIC_API_KEY"] }
  #     config.provider :bedrock, preset: :bedrock, region: "us-east-1", preprocessors: :aws_sigv4
  #   end
  module Presets
    TABLE = {
      openai: {
        url: "https://api.openai.com",
        serializer: :open_responses,
        auth_header: "authorization",
        auth_format: "Bearer %s"
      },
      anthropic: {
        url: "https://api.anthropic.com",
        serializer: :messages,
        auth_header: "x-api-key",
        auth_format: "%s",
        headers: {"anthropic-version" => ANTHROPIC_VERSION}
      },
      gemini: {
        url: "https://generativelanguage.googleapis.com",
        serializer: :gemini,
        auth_header: "x-goog-api-key",
        auth_format: "%s"
      },
      bedrock: {
        url: "https://bedrock-runtime.%{region}.amazonaws.com",
        serializer: :converse,
        path: "model/{model}/converse",
        auth_header: "authorization",
        auth_format: "Bearer %s",
        requires_region: true
      }
    }.freeze

    class << self
      # Fetch a preset by name.
      #
      # @param name [Symbol, String] the preset name
      # @return [Hash] the preset attributes
      # @raise [ArgumentError] if the preset is unknown
      def fetch(name)
        TABLE[name.to_sym] || raise(ArgumentError, "Unknown preset: #{name.inspect}. Valid presets: #{TABLE.keys.map(&:inspect).join(", ")}")
      end

      # Resolve a preset's base URL, filling in the region placeholder when
      # the preset requires one.
      #
      # @param preset [Hash] a preset row from {TABLE}
      # @param region [String, nil] the region for region-templated URLs
      # @return [String] the resolved base URL
      # @raise [ArgumentError] if the preset requires a region and none is given
      def url(preset, region: nil)
        if preset[:requires_region]
          raise ArgumentError, "This preset requires a region: (e.g. \"us-east-1\")" if region.nil?
          format(preset[:url], region: region)
        else
          preset[:url]
        end
      end
    end
  end
end
