# frozen_string_literal: true

module PatientLLM
  class Agent
    # The failure delivered to an agent's failed hook. Wraps the error
    # together with the rest of the invocation state so the hook has one
    # object with everything it needs: the error itself, the HTTP exchange
    # (when there was one), the context passed to ask/continue, and the
    # serializable conversation state.
    class Failure
      # @return [PatientHttp::Error] the underlying error; exposes error_type,
      #   message, error_class, and request_id
      attr_reader :error

      # @return [PromptBuilder::Session] the session at the time of the failure
      attr_reader :session

      # @return [PatientHttp::Response, nil] the HTTP response for HTTP
      #   errors; nil for non-HTTP errors (timeouts, connection failures)
      attr_reader :http_response

      # @return [String, nil] the request id of the HTTP exchange. May be nil
      #   for non-HTTP errors.
      attr_reader :http_request_id

      # @return [PatientHttp::CallbackArgs] the context passed to ask/continue
      attr_reader :context

      def initialize(error, session:, http_response: nil, http_request_id: nil, context: nil)
        @error = error
        @session = session
        @http_response = http_response
        @http_request_id = http_request_id
        @context = context || PatientHttp::CallbackArgs.new
      end

      # A value from the context passed to ask/continue. Shorthand for
      # `failure.context[key]`.
      #
      # @param key [String, Symbol] the context key
      # @return [Object] the context value
      # @raise [KeyError] if the key is not in the context
      def [](key)
        context[key]
      end

      # The category of the error (e.g. :timeout, :client_error).
      #
      # @return [Symbol, nil]
      def error_type
        error.error_type
      end

      # The error message.
      #
      # @return [String]
      def message
        error.message
      end

      # The class name of the original exception.
      #
      # @return [String, nil]
      def error_class
        error.error_class
      end

      # The JSON-native session state at the time of the failure.
      #
      # @return [Hash]
      def state
        session.to_h
      end
    end
  end
end
