# frozen_string_literal: true

module PatientLLM
  class Agent
    # The response delivered to an agent's hooks. Wraps the parsed
    # PromptBuilder::Response together with the session so hooks have one
    # object with everything they need: the text, the parsed structured
    # output, usage, and the serializable conversation state for multi-turn
    # persistence.
    class Response
      # @return [PromptBuilder::Response] the underlying LLM response
      attr_reader :llm_response

      # @return [PromptBuilder::Session] the session including this response
      attr_reader :session

      def initialize(llm_response, session:, output_schema: nil)
        @llm_response = llm_response
        @session = session
        @output_schema = output_schema
      end

      # The text of the response.
      #
      # @return [String, nil]
      def text
        llm_response.text
      end

      # The structured output parsed per the agent's output schema.
      #
      # @return [Hash, Array, Object] the parsed JSON value
      # @raise [StructuredOutputError] if the agent declares no output schema
      #   or the response text cannot be parsed as JSON
      def object
        return @object if defined?(@object)

        unless @output_schema
          raise StructuredOutputError.new("The agent has no output schema; declare one with `output` or use `text`", text: text)
        end

        @object = begin
          llm_response.parsed_json!
        rescue PromptBuilder::ParseError => e
          raise StructuredOutputError.new(e.message, text: text)
        end
      end

      # The JSON-native session state for persistence. Store this and pass it
      # to `Agent.continue` to resume the conversation later.
      #
      # @return [Hash]
      def state
        session.to_h
      end

      # Token usage for the response.
      #
      # @return [PromptBuilder::Usage, nil]
      def usage
        llm_response.usage
      end

      # The model that produced the response.
      #
      # @return [String, nil]
      def model
        llm_response.model
      end

      # Whether the response contains tool calls.
      #
      # @return [Boolean]
      def has_tool_calls?
        llm_response.has_tool_calls?
      end

      # The tool calls in the response.
      #
      # @return [Array<PromptBuilder::Items::FunctionCall>]
      def tool_calls
        llm_response.tool_calls
      end
    end
  end
end
