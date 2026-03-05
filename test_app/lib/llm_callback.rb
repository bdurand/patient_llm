# frozen_string_literal: true

class LLMCallback
  # Handle successful completion of an LLM request
  #
  # @param chat [PatientHttp::LLM::Chat] the chat instance
  # @param message [PatientHttp::LLM::Message] the response message
  # @param callback_args [Array] additional callback arguments
  # @param response [PatientHttp::LLM::Response] the response object
  def on_complete(chat, message, callback_args, response)
    # Add the assistant's response to the chat
    chat.add_message(message) if message

    # Build result payload
    result = {
      success: true,
      message: {
        role: message.role.to_s,
        content: message.content,
        model_id: message.model_id,
        input_tokens: message.input_tokens,
        output_tokens: message.output_tokens,
        duration: response.duration&.round(1)
      },
      chat: chat.as_json,
      timestamp: Time.now.iso8601
    }

    ChatService.set_result(response.request_id, result)

    Sidekiq.logger.info("LLM completion stored: #{message.content&.slice(0, 100)}...")
  end

  # Handle errors during an LLM request
  #
  # @param chat [PatientHttp::LLM::Chat] the chat instance
  # @param callback_args [Array] additional callback arguments
  # @param error [PatientHttp::LLM::Error] the error object
  def on_error(chat, callback_args, error)
    # Build error result payload
    result = {
      success: false,
      error: {
        type: error.error_type.to_s,
        message: error.message,
        error_class: error.error_class
      },
      chat: chat.as_json,
      timestamp: Time.now.iso8601
    }

    ChatService.set_result(error.request_id, result)
    Sidekiq.logger.error("LLM error: #{error.error_type} - #{error.message}")
  end
end
