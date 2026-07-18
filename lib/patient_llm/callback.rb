# frozen_string_literal: true

require "json"

module PatientLLM
  # Callback class that receives async HTTP responses from PatientHttp and
  # dispatches to the user's callback.
  #
  # When the response contains tool calls and a handler is available for them,
  # this class executes them automatically and re-issues the request until the
  # model returns a final text response or a tool raises {HaltError}. Tool
  # handlers are resolved from the user callback itself when it implements
  # `handles_tool?`/`invoke_tool` (as {Agent} subclasses do), falling back to
  # the global PromptBuilder tool registry. Iteration is capped at the resolved
  # max_tool_iterations for the request (default {MAX_TOOL_ITERATIONS}).
  #
  # The user callback receives a `PromptBuilder::Response` object. Access
  # the response text via `response.text`, token usage via `response.usage`,
  # and model id via `response.model`.
  class Callback
    # Default maximum number of tool-execution rounds before the loop raises.
    # Configurable per provider or per request with the max_tool_iterations option.
    MAX_TOOL_ITERATIONS = 10

    # Supported keyword parameters for each user callback method, along with the
    # one parameter that must always be declared.
    CALLBACK_PARAMS = {
      on_complete: {allowed: %i[session provider llm_response callback_args http_response request_id]},
      on_tool_use: {allowed: %i[session provider llm_response callback_args http_response request_id]},
      on_error: {allowed: %i[session provider callback_args error http_response request_id], required: :error}
    }.freeze

    # Validate that a user callback class declares supported keyword parameters.
    #
    # Each defined callback method must use keyword parameters drawn from the
    # supported set for that method and must declare the required parameter
    # (`error` is required for on_error). A
    # `**kwargs` splat is permitted and receives every available value.
    #
    # @param callback_class [Class] The user callback class
    # @raise [ArgumentError] If a method uses positional or unsupported parameters
    # @return [void]
    def self.validate_callback_class!(callback_class)
      CALLBACK_PARAMS.each do |method_name, spec|
        next unless callback_class.method_defined?(method_name)

        params = callback_class.instance_method(method_name).parameters
        splat = params.any? { |type, _| type == :keyrest }
        declared = []
        params.each do |type, name|
          case type
          when :key, :keyreq
            declared << name
          when :keyrest, :block
            next
          else
            raise ArgumentError, "#{callback_class}##{method_name} must use keyword parameters; found positional parameter #{name.inspect}"
          end
        end

        allowed = Array(spec[:allowed])
        unknown = declared - allowed
        unless unknown.empty?
          raise ArgumentError, "#{callback_class}##{method_name} has unsupported parameter(s): #{unknown.map(&:inspect).join(", ")}. Allowed: #{allowed.map(&:inspect).join(", ")}"
        end

        required = Array(spec[:required])
        unless splat || required.empty? || (required & declared).any?
          raise ArgumentError, "#{callback_class}##{method_name} must declare the #{required.map(&:inspect).join(", ")} keyword parameter(s)"
        end
      end
    end

    # Handle a successful LLM completion response.
    #
    # @param response [PatientHttp::Response] The async HTTP response
    # @return [void]
    def on_complete(response)
      callback_args = response.callback_args
      session = restore_session(callback_args)
      provider_name = callback_args[:provider]
      user_callback = resolve_user_callback(callback_args)
      original_request_id = callback_args.fetch(:original_request_id, nil) || response.request_id

      prepare_user_callback(user_callback, session: session, provider: provider_name, callback_args: callback_args, http_response: response, request_id: original_request_id)

      serializer = resolve_serializer(callback_args)
      llm_response = PromptBuilder::Response.parse(response.json, serializer)

      if should_auto_execute_tools?(llm_response, user_callback)
        continue_tool_loop(session, provider_name, llm_response, callback_args, response, user_callback, original_request_id)
      else
        session.add_response(llm_response)
        invoke_user_callback(user_callback, :on_complete, session: session, provider: provider_name, llm_response: llm_response, callback_args: user_callback_args(callback_args), http_response: response, request_id: original_request_id)
      end
    end

    # Handle an error during an LLM request.
    #
    # @param error [PatientHttp::Error] The error
    # @return [void]
    def on_error(error)
      callback_args = error.callback_args
      session = restore_session(callback_args)
      provider_name = callback_args[:provider]
      http_response = error.respond_to?(:response) ? error.response : nil
      original_request_id = callback_args.fetch(:original_request_id, nil) || http_response&.request_id
      user_callback = resolve_user_callback(callback_args)
      prepare_user_callback(user_callback, session: session, provider: provider_name, callback_args: callback_args, http_response: http_response, request_id: original_request_id)
      invoke_user_callback(user_callback, :on_error, session: session, provider: provider_name, callback_args: user_callback_args(callback_args), error: error, http_response: http_response, request_id: original_request_id)
    end

    private

    # Give stateful callbacks (like Agent) access to the invocation state
    # before hooks and tool execution run. The callback opts in by defining
    # a `prepare` method.
    def prepare_user_callback(user_callback, session:, provider:, callback_args:, http_response:, request_id:)
      return unless user_callback.respond_to?(:prepare)

      user_callback.prepare(
        session: session,
        provider: provider,
        callback_args: user_callback_args(callback_args),
        http_response: http_response,
        request_id: request_id
      )
    end

    def invoke_user_callback(user_callback, method_name, **values)
      params = user_callback.method(method_name).parameters
      kwargs =
        if params.any? { |type, _| type == :keyrest || type == :rest }
          values
        else
          names = params.map { |_, name| name }
          values.slice(*names)
        end
      user_callback.public_send(method_name, **kwargs)
    end

    def restore_session(callback_args)
      session_hash = callback_args.fetch(:session, {})
      session_hash = fetch_offloaded_session(session_hash) if session_hash.is_a?(Hash) && session_hash.key?(SESSION_REF_KEY)
      PromptBuilder::Session.from_h(session_hash)
    end

    def fetch_offloaded_session(reference_hash)
      reference = reference_hash[SESSION_REF_KEY]
      store_name = reference["payload_store"]
      store = PatientHttp.default_configuration&.payload_store(store_name)
      unless store
        raise ArgumentError, "Session was offloaded to payload store #{store_name.inspect} but it is not registered on the PatientHttp configuration"
      end

      session_hash = store.fetch(reference["key"])
      if session_hash.nil?
        raise ArgumentError, "Offloaded session #{reference["key"].inspect} was not found in payload store #{store_name.inspect}"
      end

      session_hash
    end

    def resolve_user_callback(callback_args)
      class_name = callback_args.fetch(:callback, nil)
      if class_name.nil? || class_name == ""
        raise ArgumentError, "No callback registered"
      end

      callback_class = PatientHttp::ClassHelper.resolve_class_name(class_name)
      callback_class.new
    end

    def user_callback_args(callback_args)
      PatientHttp::CallbackArgs.new(callback_args[:custom] || {})
    end

    def resolve_serializer(callback_args)
      serializer = callback_args.fetch(:serializer, nil)
      return serializer.to_sym if serializer && !serializer.to_s.empty?

      # Fallback for in-flight jobs enqueued before the serializer traveled in
      # the callback args.
      request_options = callback_args.fetch(:request_options, nil) || {}
      return request_options["serializer"].to_sym if request_options["serializer"] && !request_options["serializer"].empty?

      provider_config = PatientLLM.provider(callback_args[:provider])
      provider_config&.dig(:serializer) || :chat_completion
    end

    def max_tool_iterations(callback_args)
      callback_args.fetch(:max_tool_iterations, MAX_TOOL_ITERATIONS).to_i
    end

    def should_auto_execute_tools?(llm_response, user_callback)
      return false unless llm_response.has_tool_calls?

      llm_response.tool_calls.any? do |call|
        callback_handles_tool?(user_callback, call.name) || PromptBuilder.tool_registry.handler_for(call.name)
      end
    end

    def callback_handles_tool?(user_callback, name)
      user_callback.respond_to?(:handles_tool?) && user_callback.handles_tool?(name)
    end

    def continue_tool_loop(session, provider_name, llm_response, callback_args, http_response, user_callback, original_request_id)
      iteration = callback_args.fetch(:tool_iteration, 0).to_i
      if iteration >= max_tool_iterations(callback_args)
        error = max_tool_iterations_error(callback_args, http_response, original_request_id)
        invoke_user_callback(user_callback, :on_error, session: session, provider: provider_name, callback_args: user_callback_args(callback_args), error: error, http_response: http_response, request_id: original_request_id)
        return
      end

      session.add_response(llm_response)

      halt = nil
      llm_response.tool_calls.each do |function_call|
        result, halted =
          if halt
            # A previous tool halted the loop. The remaining calls are not
            # executed, but they still need outputs so every function call
            # has one and the session remains valid for continuation.
            ["Tool execution halted", nil]
          else
            execute_tool(function_call, user_callback, callback_args)
          end
        halt ||= halted

        session.add_item(
          PromptBuilder::Items::FunctionCallOutput.new(
            call_id: function_call.call_id,
            output: result
          )
        )
      end

      if halt
        halt_response = PromptBuilder::Response.from_text(
          halt.content.to_s,
          model: llm_response.model,
          usage: llm_response.usage
        )
        # The synthesized message is added with add_item rather than
        # add_response: the server never saw the tool outputs or this message,
        # so a server-state session's response boundary must not advance past
        # them or a later continue would drop them from the request.
        halt_response.output.each { |item| session.add_item(item) }
        invoke_user_callback(user_callback, :on_complete, session: session, provider: provider_name, llm_response: halt_response, callback_args: user_callback_args(callback_args), http_response: http_response, request_id: original_request_id)
        return
      end

      if user_callback.respond_to?(:on_tool_use)
        invoke_user_callback(user_callback, :on_tool_use, session: session, provider: provider_name, llm_response: llm_response, callback_args: user_callback_args(callback_args), http_response: http_response, request_id: original_request_id)
      end

      # Re-ask with the updated session, passing the original request options
      # through wholesale so per-request overrides survive every iteration.
      PatientLLM.dispatch(
        session,
        provider: provider_name,
        callback: callback_args[:callback],
        callback_args: callback_args[:custom] || {},
        request_options: callback_args.fetch(:request_options, nil) || {},
        tool_iteration: iteration + 1,
        original_request_id: original_request_id
      )
    end

    def max_tool_iterations_error(callback_args, http_response, request_id)
      limit = max_tool_iterations(callback_args)
      exception = MaxToolIterationsError.new("Tool-call loop exceeded #{limit} iterations")
      PatientHttp::RequestError.new(
        class_name: exception.class.name,
        message: exception.message,
        backtrace: [],
        error_type: :max_tool_iterations,
        duration: http_response&.duration,
        request_id: request_id,
        url: http_response&.url,
        http_method: http_response&.http_method
      )
    end

    def execute_tool(function_call, user_callback, callback_args)
      name = function_call.name
      args = function_call.parsed_arguments

      result =
        if callback_handles_tool?(user_callback, name)
          invoke_callback_tool(user_callback, name, args, callback_args)
        else
          PromptBuilder.tool_registry.invoke(name, args)
        end
      [format_result(result), nil]
    rescue HaltError => e
      [format_result(e.content), e]
    rescue PromptBuilder::ToolNotFoundError => e
      [e.message, nil]
    rescue => e
      ["Error executing tool #{function_call.name}: #{e.class}: #{e.message}", nil]
    end

    # Invoke a tool handled by the user callback, passing the user callback
    # args when the invoke_tool implementation accepts a callback_args keyword
    # (as {Agent} does, to expose the context to tool methods).
    def invoke_callback_tool(user_callback, name, args, callback_args)
      accepts_callback_args = user_callback.method(:invoke_tool).parameters.any? do |type, param_name|
        type == :keyrest || ((type == :key || type == :keyreq) && param_name == :callback_args)
      end

      if accepts_callback_args
        user_callback.invoke_tool(name, args, callback_args: user_callback_args(callback_args))
      else
        user_callback.invoke_tool(name, args)
      end
    end

    def format_result(result)
      case result
      when String then result
      when nil then ""
      else
        JSON.generate(result)
      end
    end
  end
end
