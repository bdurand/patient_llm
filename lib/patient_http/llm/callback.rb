# frozen_string_literal: true

module PatientHttp
  module LLM
    # Callback class for handling async LLM responses.
    # When the response contains tool calls and the chat has tools registered,
    # tools are executed automatically and the conversation continues until
    # the LLM returns a text response or a tool halts the loop.
    class Callback
      def on_complete(response)
        callback_args = response.callback_args
        chat = Chat.load(callback_args[:chat])
        provider_slug = chat.provider
        model_id = chat.model

        faraday_response = to_faraday_response(response)
        provider_instance = lookup_provider_instance(model_id, provider_slug)
        message = provider_instance.send(:parse_completion_response, faraday_response)

        if message.tool_call? && chat.tools.any?
          handle_tool_calls(chat, message, callback_args, response)
        else
          user_callback = chat_callback(callback_args)
          user_callback.on_complete(chat, message, chat_callback_args(callback_args), response)
        end
      end

      def on_error(error)
        callback_args = error.callback_args
        chat = Chat.load(callback_args[:chat])
        user_callback = chat_callback(callback_args)
        user_callback.on_error(chat, chat_callback_args(callback_args), error)
      end

      private

      def handle_tool_calls(chat, message, callback_args, response)
        iteration = (callback_args.fetch(:tool_iteration, 0) || 0) + 1

        if iteration > chat.max_tool_iterations
          user_callback = chat_callback(callback_args)
          error = ToolIterationLimitError.new(
            "Tool call loop exceeded maximum of #{chat.max_tool_iterations} iterations"
          )
          user_callback.on_error(chat, chat_callback_args(callback_args), error)
          return
        end

        chat.add_message(message)

        halt_result = nil
        message.tool_calls.each_value do |tool_call|
          result = execute_tool(chat.tools, tool_call)

          if result.is_a?(RubyLLM::Tool::Halt)
            halt_result = result
            result = result.content
          end

          chat.add_message(role: :tool, content: result.to_s, tool_call_id: tool_call.id)
        end

        if halt_result
          halt_message = RubyLLM::Message.new(role: :assistant, content: halt_result.content.to_s)
          user_callback = chat_callback(callback_args)
          user_callback.on_complete(chat, halt_message, chat_callback_args(callback_args), response)
        else
          continue_after_tool_calls(chat, callback_args, iteration)
        end
      end

      def execute_tool(tools, tool_call)
        tool = tools[tool_call.name.to_sym]
        unless tool
          return {error: "Model tried to call unavailable tool `#{tool_call.name}`. Available tools: #{tools.keys.to_json}."}.to_s
        end

        tool.call(tool_call.arguments)
      end

      def continue_after_tool_calls(chat, callback_args, iteration)
        custom_args = callback_args[:custom] || {}
        custom_args = custom_args.transform_keys(&:to_s) if custom_args.is_a?(Hash)

        model_info, provider_instance = RubyLLM::Models.resolve(
          chat.model, provider: chat.provider, assume_exists: true
        )

        payload = chat.send(:build_payload, model_info, provider_instance)

        base_url = chat.api_base || provider_instance.api_base
        request_url = URI.join(base_url, chat.completion_path).to_s
        request_headers = provider_instance.headers.merge(chat.headers)

        PatientHttp.post(
          request_url,
          json: payload,
          headers: request_headers,
          raise_error_responses: true,
          callback: PatientHttp::LLM::Callback,
          callback_args: {
            chat: chat.as_json,
            chat_callback: callback_args[:chat_callback],
            custom: custom_args,
            tool_iteration: iteration
          }
        )
      end

      # Convert a PatientHttp::Response to a Faraday::Response.
      #
      # @param response [PatientHttp::Response] The async response to convert.
      # @return [Faraday::Response] A Faraday response object.
      def to_faraday_response(response)
        env = Faraday::Env.new
        env.method = response.http_method
        env.url = URI(response.url)
        env.status = response.status
        env.response_headers = response.headers.to_h
        env.response_body = response.json? ? response.json : response.body

        Faraday::Response.new(env)
      end

      def lookup_provider_instance(model_id, provider_slug)
        _, provider_instance = RubyLLM::Models.resolve(model_id, provider: provider_slug, assume_exists: true)
        provider_instance
      end

      def chat_callback(callback_args)
        callback_class = PatientHttp::ClassHelper.resolve_class_name(callback_args[:chat_callback])
        callback_class.new
      end

      def chat_callback_args(callback_args)
        PatientHttp::CallbackArgs.new(callback_args[:custom])
      end
    end
  end
end
