# frozen_string_literal: true

require "json"

module PatientLLM
  # Callback class that receives async HTTP responses from PatientHttp and
  # dispatches to the user's callback.
  #
  # When the response contains tool calls and the global PromptBuilder tool
  # registry has handlers for those tools, this class executes them
  # automatically and re-issues the request until the model returns a final
  # text response or a tool raises {HaltError}. Iteration is capped at
  # {MAX_TOOL_ITERATIONS} to prevent runaway loops.
  #
  # The user callback receives a `PromptBuilder::Response` object. Access
  # the response text via `response.text`, token usage via `response.usage`,
  # and model id via `response.model`.
  class Callback
    # Maximum number of tool-execution rounds before the loop raises.
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
      request_options = callback_args[:request_options] || {}
      user_callback = resolve_user_callback(callback_args)
      original_request_id = callback_args.fetch(:original_request_id, nil) || response.request_id

      serializer = resolve_serializer(provider_name, request_options)
      llm_response = PromptBuilder::Response.parse(response.json, serializer)

      if should_auto_execute_tools?(llm_response)
        continue_tool_loop(session, provider_name, llm_response, callback_args, response, user_callback, request_options, original_request_id)
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
      original_request_id = callback_args.fetch(:original_request_id, http_response&.request_id)
      user_callback = resolve_user_callback(callback_args)
      invoke_user_callback(user_callback, :on_error, session: session, provider: provider_name, callback_args: user_callback_args(callback_args), error: error, http_response: http_response, request_id: original_request_id)
    end

    private

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
      PromptBuilder::Session.from_h(session_hash)
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

    def resolve_serializer(provider_name, request_options)
      if request_options["serializer"] && !request_options["serializer"].empty?
        return request_options["serializer"].to_sym
      end

      provider_config = PatientLLM.provider(provider_name)
      provider_config&.dig(:serializer) || :chat_completion
    end

    def should_auto_execute_tools?(llm_response)
      return false unless llm_response.has_tool_calls?

      llm_response.tool_calls.any? do |call|
        PromptBuilder.tool_registry.handler_for(call.name)
      end
    end

    def continue_tool_loop(session, provider_name, llm_response, callback_args, http_response, user_callback, request_options, original_request_id)
      iteration = callback_args.fetch(:tool_iteration, 0).to_i
      if iteration >= MAX_TOOL_ITERATIONS
        error = max_tool_iterations_error(http_response, original_request_id)
        invoke_user_callback(user_callback, :on_error, session: session, provider: provider_name, callback_args: user_callback_args(callback_args), error: error, http_response: http_response, request_id: original_request_id)
        return
      end

      session.add_response(llm_response)

      halt = nil
      llm_response.tool_calls.each do |function_call|
        result, halted = execute_tool(function_call)
        halt = halted if halted

        session.add_item(
          PromptBuilder::Items::FunctionCallOutput.new(
            call_id: function_call.call_id,
            output: result
          )
        )
        break if halt
      end

      if halt
        content = halt.content
        halt_response = PromptBuilder::Response.new(
          model: llm_response.model,
          status: "completed",
          output: [
            PromptBuilder::Items::Message.new(
              role: "assistant",
              content: [PromptBuilder::Content::OutputText.new(text: content || "")]
            )
          ],
          usage: llm_response.usage
        )
        session.add_response(halt_response)
        invoke_user_callback(user_callback, :on_complete, session: session, provider: provider_name, llm_response: halt_response, callback_args: user_callback_args(callback_args), http_response: http_response, request_id: original_request_id)
        return
      end

      if user_callback.respond_to?(:on_tool_use)
        invoke_user_callback(user_callback, :on_tool_use, session: session, provider: provider_name, llm_response: llm_response, callback_args: user_callback_args(callback_args), http_response: http_response, request_id: original_request_id)
      end

      # Re-ask with the updated session
      ask_kwargs = {
        provider: provider_name.to_sym,
        callback: callback_args[:callback],
        callback_args: callback_args[:custom],
        tool_iteration: iteration + 1,
        original_request_id: original_request_id
      }

      # Restore per-request overrides
      ask_kwargs[:url] = request_options["url"] if request_options["url"]
      ask_kwargs[:serializer] = request_options["serializer"].to_sym if request_options["serializer"]
      ask_kwargs[:path] = request_options["path"] if request_options["path"]
      ask_kwargs[:headers] = request_options["headers"] if request_options["headers"]
      ask_kwargs[:params] = request_options["params"] if request_options["params"]
      ask_kwargs[:preprocessors] = request_options["preprocessors"] if request_options["preprocessors"]

      PatientLLM.ask(session, **ask_kwargs)
    end

    def max_tool_iterations_error(http_response, request_id)
      exception = MaxToolIterationsError.new("Tool-call loop exceeded #{MAX_TOOL_ITERATIONS} iterations")
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

    def execute_tool(function_call)
      name = function_call.name
      args = function_call.parsed_arguments

      result = PromptBuilder.tool_registry.invoke(name, args)
      [format_result(result), nil]
    rescue HaltError => e
      [format_result(e.content), e]
    rescue PromptBuilder::ToolNotFoundError => e
      [e.message, nil]
    rescue => e
      ["Error executing tool #{function_call.name}: #{e.class}: #{e.message}", nil]
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
