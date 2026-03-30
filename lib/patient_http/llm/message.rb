# frozen_string_literal: true

module PatientHttp
  module LLM
    # Value object representing an LLM message.
    class Message
      attr_reader :role, :content, :tool_calls, :tool_call_id, :model_id, :input_tokens, :output_tokens

      # @param role [String, Symbol] Message role (system, user, assistant, tool)
      # @param content [String, nil] Message content
      # @param tool_calls [Hash] Tool calls keyed by ID
      # @param tool_call_id [String, nil] ID of the tool call this message responds to
      # @param model_id [String, nil] Model that generated this message
      # @param input_tokens [Integer, nil] Number of input tokens used
      # @param output_tokens [Integer, nil] Number of output tokens used
      def initialize(role:, content: nil, tool_calls: {}, tool_call_id: nil, model_id: nil, input_tokens: nil, output_tokens: nil)
        @role = role.to_sym
        @content = content
        @tool_calls = tool_calls
        @tool_call_id = tool_call_id
        @model_id = model_id
        @input_tokens = input_tokens
        @output_tokens = output_tokens
      end

      # Returns true if this message contains tool calls.
      #
      # @return [Boolean]
      def tool_call?
        !tool_calls.empty?
      end
    end
  end
end
