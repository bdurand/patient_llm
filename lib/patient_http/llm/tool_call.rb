# frozen_string_literal: true

module PatientHttp
  module LLM
    # Value object representing a tool call from an LLM response.
    class ToolCall
      attr_reader :id, :name, :arguments

      class << self
        # Reconstruct a ToolCall from a hash (from a serialized chat).
        #
        # @param id [String] Unique identifier for the tool call
        # @param data [Hash] Hash with "name" and "arguments" (string or symbol keys)
        # @return [ToolCall]
        def load(id, data)
          name = data[:name] || data["name"]
          arguments = data[:arguments] || data["arguments"] || {}
          new(id: id, name: name, arguments: arguments)
        end
      end

      # @param id [String] Unique identifier for the tool call
      # @param name [String] Name of the tool to call
      # @param arguments [Hash] Arguments for the tool call
      def initialize(id:, name:, arguments:)
        @id = id
        @name = name
        @arguments = arguments
      end

      # Return a JSON-compatible hash representation.
      #
      # @return [Hash] hash with string keys
      def as_json
        {
          "name" => name,
          "arguments" => deep_stringify_keys(arguments)
        }
      end

      alias_method :to_h, :as_json

      private

      def deep_stringify_keys(value)
        case value
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| deep_stringify_keys(v) }
        when Array
          value.map { |v| deep_stringify_keys(v) }
        else
          value
        end
      end
    end
  end
end
