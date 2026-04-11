# frozen_string_literal: true

require "json"

module PatientHttp
  module LLM
    # Callback class for handling async LLM responses.
    class Callback
      # Handle a successful LLM completion response.
      #
      # @param response [PatientHttp::Response] The async response
      # @return [void]
      def on_complete(response)
        callback_args = response.callback_args
        chat = Chat.load(callback_args[:chat])

        body = response.json? ? response.json : JSON.parse(response.body)
        message = ResponseParser.parse(body)

        callback = chat_callback(callback_args)
        callback.on_complete(chat, message, chat_callback_args(callback_args), response)
      end

      # Handle an error during an LLM request.
      #
      # @param error [PatientHttp::Error] The error
      # @return [void]
      def on_error(error)
        callback_args = error.callback_args
        chat = Chat.load(callback_args[:chat])
        callback = chat_callback(callback_args)
        callback.on_error(chat, chat_callback_args(callback_args), error)
      end

      private

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
