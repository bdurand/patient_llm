# frozen_string_literal: true

module PatientHttp
  module LLM
    # Value object representing a tool call from an LLM response.
    class ToolCall
      attr_reader :id, :name, :arguments

      # @param id [String] Unique identifier for the tool call
      # @param name [String] Name of the tool to call
      # @param arguments [Hash] Arguments for the tool call
      def initialize(id:, name:, arguments:)
        @id = id
        @name = name
        @arguments = arguments
      end
    end
  end
end
