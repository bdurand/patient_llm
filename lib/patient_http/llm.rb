# frozen_string_literal: true

require "ruby_llm"
require "patient_http"

require_relative "llm/chat"
require_relative "llm/callback"

module PatientHttp
  module LLM
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

    class ToolIterationLimitError < StandardError
      attr_reader :error_type

      def initialize(message)
        @error_type = :tool_iteration_limit
        super
      end
    end
  end
end
