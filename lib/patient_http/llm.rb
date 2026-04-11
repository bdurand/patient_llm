# frozen_string_literal: true

require "patient_http"

require_relative "llm/provider"
require_relative "llm/tool_call"
require_relative "llm/message"
require_relative "llm/tool"
require_relative "llm/payload_builder"
require_relative "llm/response_parser"
require_relative "llm/chat"
require_relative "llm/callback"

module PatientHttp
  module LLM
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

    class << self
      # Configure providers for LLM requests.
      #
      # @yield [Configuration]
      # @return [void]
      def configure
        @configuration ||= Configuration.new
        yield @configuration
      end

      # Look up a registered provider by name.
      #
      # @param name [Symbol, String] Provider name
      # @return [Hash, nil] Provider config with :url and :headers keys
      def provider(name)
        @configuration&.lookup(name)
      end
    end
  end
end
