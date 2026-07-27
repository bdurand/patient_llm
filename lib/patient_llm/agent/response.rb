# frozen_string_literal: true

module PatientLLM
  class Agent
    # The response delivered to an agent's hooks. Wraps the parsed
    # PromptBuilder::Response together with the rest of the invocation state
    # so hooks have one object with everything they need: the text, the
    # parsed structured output, usage, the HTTP exchange, the context passed
    # to ask/continue, and the serializable conversation state for multi-turn
    # persistence.
    class Response
      # @return [PromptBuilder::Response] the underlying LLM response
      attr_reader :llm_response

      # @return [PromptBuilder::Session] the session including this response
      attr_reader :session

      # @return [PatientHttp::Response, nil] the HTTP response that produced
      #   this LLM response. In completed this is the final request's
      #   response; in tool_round it is that round's response.
      attr_reader :http_response

      # @return [String, nil] the request id of the HTTP exchange
      attr_reader :http_request_id

      # @return [PatientHttp::CallbackArgs] the context passed to ask/continue
      attr_reader :context

      def initialize(llm_response, session:, output_schema: nil, http_response: nil, http_request_id: nil, context: nil)
        @llm_response = llm_response
        @session = session
        @output_schema = output_schema
        @http_response = http_response
        @http_request_id = http_request_id
        @context = context || PatientHttp::CallbackArgs.new
      end

      # A value from the context passed to ask/continue. Shorthand for
      # `response.context[key]`.
      #
      # @param key [String, Symbol] the context key
      # @return [Object] the context value
      # @raise [KeyError] if the key is not in the context
      def [](key)
        context[key]
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
