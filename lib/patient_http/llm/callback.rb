# frozen_string_literal: true

require "json"

module PatientHttp
  module LLM
    # Callback class that receives async HTTP responses from PatientHttp and
    # dispatches to the user's chat callback.
    #
    # When the response contains tool calls and the chat has matching tools
    # registered, this class executes the tools automatically and re-issues
    # the chat request until the model returns a final text response (or a
    # tool returns `Tool::Halt`). Iteration is capped at
    # {MAX_TOOL_ITERATIONS} per conversation to prevent runaway loops.
    class Callback
      # Maximum number of tool-execution rounds per conversation before the
      # loop gives up and surfaces an error to the user callback.
      MAX_TOOL_ITERATIONS = 10

      # Handle a successful LLM completion response.
      #
      # @param response [PatientHttp::Response] The async response
      # @return [void]
      def on_complete(response)
        callback_args = response.callback_args
        chat = Chat.load(callback_args[:chat])
        user_callback = resolve_user_callback(callback_args)

        body = parse_body(response)
        message = ResponseParser.parse(body)

        if should_auto_execute_tools?(chat, message)
          continue_tool_loop(chat, message, callback_args, response, user_callback)
        else
          user_callback.on_complete(chat, message, chat_callback_args(callback_args), response)
        end
      end

      # Handle an error during an LLM request.
      #
      # @param error [PatientHttp::Error] The error
      # @return [void]
      def on_error(error)
        callback_args = error.callback_args
        chat = Chat.load(callback_args[:chat])
        user_callback = resolve_user_callback(callback_args)
        user_callback.on_error(chat, chat_callback_args(callback_args), error)
      end

      private

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
        class_name = callback_args.fetch(:chat_callback, nil)
        if class_name.nil? || class_name == ""
          raise ArgumentError.new("No chat_callback registered; Chat was created without a callback:")
        end

        callback_class = PatientHttp::ClassHelper.resolve_class_name(class_name)
        callback_class.new
      end

      def chat_callback_args(callback_args)
        PatientHttp::CallbackArgs.new(callback_args.fetch(:custom, {}) || {})
      end

      def should_auto_execute_tools?(chat, message)
        message.tool_call? && !chat.tools.empty?
      end

      def continue_tool_loop(chat, message, callback_args, response, user_callback)
        iteration = callback_args.fetch(:tool_iteration, 0).to_i
        if iteration >= MAX_TOOL_ITERATIONS
          raise "Tool-call loop exceeded #{MAX_TOOL_ITERATIONS} iterations"
        end

        chat.add_message(message)

        halt = nil
        message.tool_calls.each do |id, tool_call|
          result = execute_tool(chat, tool_call)
          if result.is_a?(Tool::Halt)
            halt = result
          end
          chat.add_message(
            role: :tool,
            content: tool_result_content(result),
            tool_call_id: id
          )
          break if halt
        end

        if halt
          halt_message = Message.new(
            role: :assistant,
            content: halt.content,
            model_id: message.model_id,
            input_tokens: message.input_tokens,
            output_tokens: message.output_tokens
          )
          user_callback.on_complete(chat, halt_message, chat_callback_args(callback_args), response)
          return
        end

        chat.ask(
          callback_args: callback_args.fetch(:custom, {}) || {},
          tool_iteration: iteration + 1
        )
      end

      def execute_tool(chat, tool_call)
        tool = chat.tools.find { |t| t.name == tool_call.name }
        unless tool
          return "Error: tool #{tool_call.name.inspect} is not registered"
        end

        tool.call(tool_call.arguments)
      rescue => e
        "Error executing tool #{tool_call.name}: #{e.class}: #{e.message}"
      end

      def tool_result_content(result)
        case result
        when Tool::Halt
          result.content.to_s
        when String
          result
        else
          result.to_json
        end
      end
    end
  end
end
