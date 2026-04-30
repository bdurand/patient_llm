# frozen_string_literal: true

class LLMCallback
  # Handle successful completion of an LLM request.
  #
  # @param session [PromptBuilder::Session] the session instance
  # @param provider [String] the provider name
  # @param llm_response [PromptBuilder::Response] the LLM response
  # @param callback_args [PatientHttp::CallbackArgs] additional callback arguments
  # @param response [PatientHttp::Response] the HTTP response object
  def on_complete(session, provider, llm_response, callback_args, response)
    result = {
      success: true,
      message: {
        role: "assistant",
        content: llm_response.text,
        model_id: llm_response.model,
        input_tokens: llm_response.usage&.input_tokens,
        output_tokens: llm_response.usage&.output_tokens,
        duration: response.duration&.round(1)
      },
      session: session.to_h,
      timestamp: Time.now.iso8601
    }

    request_id = callback_args.fetch("original_request_id", nil) || response.request_id
    ChatService.set_result(request_id, result)

    Sidekiq.logger.info("LLM completion stored: #{llm_response.text&.slice(0, 100)}...")
  end

  # Handle errors during an LLM request.
  #
  # @param session [PromptBuilder::Session] the session instance
  # @param provider [String] the provider name
  # @param callback_args [PatientHttp::CallbackArgs] additional callback arguments
  # @param error [PatientHttp::Error] the error object
  def on_error(session, provider, callback_args, error)
    result = {
      success: false,
      error: {
        type: error.error_type.to_s,
        message: error.message,
        error_class: error.error_class
      },
      session: session.to_h,
      timestamp: Time.now.iso8601
    }

    request_id = callback_args["original_request_id"] || error.request_id
    ChatService.set_result(request_id, result)
    Sidekiq.logger.error("LLM error: #{error.error_type} - #{error.message}")
  end
end
