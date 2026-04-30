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

      serializer = resolve_serializer(provider_name, request_options)
      body = parse_body(response)
      llm_response = PromptBuilder::Response.parse(body, serializer)

      if should_auto_execute_tools?(llm_response)
        continue_tool_loop(session, provider_name, llm_response, callback_args, response, user_callback, request_options)
      else
        session.add_response(llm_response)
        user_callback.on_complete(session, provider_name, llm_response, user_callback_args(callback_args), response)
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
      user_callback = resolve_user_callback(callback_args)
      user_callback.on_error(session, provider_name, user_callback_args(callback_args), error)
    end

    private

    def restore_session(callback_args)
      session_hash = callback_args.fetch(:session, {})
      PromptBuilder::Session.from_h(session_hash)
    end

    def parse_body(response)
      if response.json?
        response.json
      else
        JSON.parse(response.body.to_s)
      end
    rescue JSON::ParserError => e
      raise "Invalid JSON response from LLM provider (status #{response.status}): #{e.message}"
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
      PatientHttp::CallbackArgs.new(callback_args.fetch(:custom, {}) || {})
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

    def continue_tool_loop(session, provider_name, llm_response, callback_args, http_response, user_callback, request_options)
      iteration = callback_args.fetch(:tool_iteration, 0).to_i
      if iteration >= MAX_TOOL_ITERATIONS
        raise "Tool-call loop exceeded #{MAX_TOOL_ITERATIONS} iterations"
      end

      # Preserve the original request_id so the final result can be stored
      # under the ID the caller is polling for.
      custom = callback_args.fetch(:custom, {}) || {}
      original_request_id = custom["original_request_id"] || http_response.request_id

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
        user_callback.on_complete(session, provider_name, halt_response, user_callback_args(callback_args), http_response)
        return
      end

      # Re-ask with the updated session
      custom_args = callback_args.fetch(:custom, {}) || {}
      custom_args = custom_args.merge("original_request_id" => original_request_id)
      ask_kwargs = {
        provider: provider_name.to_sym,
        callback: callback_args[:callback],
        callback_args: custom_args,
        tool_iteration: iteration + 1
      }

      # Restore per-request overrides
      ask_kwargs[:url] = request_options["url"] if request_options["url"]
      ask_kwargs[:serializer] = request_options["serializer"].to_sym if request_options["serializer"]
      ask_kwargs[:completion_path] = request_options["completion_path"] if request_options["completion_path"]
      ask_kwargs[:headers] = request_options["headers"] if request_options["headers"]
      ask_kwargs[:params] = request_options["params"] if request_options["params"]

      PatientLLM.ask(session, **ask_kwargs)
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
