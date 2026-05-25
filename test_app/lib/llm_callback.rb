# frozen_string_literal: true

class LLMCallback
  # Handle successful completion of an LLM request.
  #
  # @param session [PromptBuilder::Session] the session instance
  # @param provider [String] the provider name
  # @param llm_response [PromptBuilder::Response] the LLM response
  # @param callback_args [PatientHttp::CallbackArgs] additional callback arguments
  # @param http_response [PatientHttp::Response] the HTTP response object
  # @param request_id [String] the original request ID
  def on_complete(session:, provider:, llm_response:, callback_args:, http_response:)
    message = {
      role: "assistant",
      content: llm_response.text,
      model_id: llm_response.model,
      input_tokens: llm_response.usage&.input_tokens,
      output_tokens: llm_response.usage&.output_tokens,
      duration: http_response.duration&.round(1)
    }

    http_response.headers.each do |key, value|
      puts "LLM response header: #{key} = #{value}"
    end

    text_format = session.text&.dig("format", "type")
    message[:structured] = true if text_format == "json_schema"

    result = {
      success: true,
      message: message,
      session: session.to_h,
      timestamp: Time.now.iso8601
    }

    request_id = callback_args[:request_id]
    ChatService.record_request_duration(request_id, http_response.duration)
    ChatService.set_result(request_id, result)

    Sidekiq.logger.info("LLM completion stored: #{llm_response.text&.slice(0, 100)}...")
  end

  def on_tool_use(llm_response:, http_response:, request_id:)
    ChatService.record_request_duration(request_id, http_response.duration)
  end

  # Handle errors during an LLM request.
  #
  # @param session [PromptBuilder::Session] the session instance
  # @param provider [String] the provider name
  # @param callback_args [PatientHttp::CallbackArgs] additional callback arguments
  # @param error [PatientHttp::Error] the error object
  # @param request_id [String] the original request ID
  def on_error(session:, provider:, callback_args:, error:)
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

    request_id = callback_args[:request_id]

    if error.respond_to?(:response) && error.response
      response = error.response

      if response.json?
        begin
          result[:error][:details] = response.json
        rescue JSON::ParserError
          # Ignore JSON parsing errors in the error response
        end
      end

      if response.json? || response.content_type.to_s.downcase.include?("text/plain")
        response_body = response.body
      end

      ChatService.record_request_duration(request_id, response.duration)
    end

    ChatService.set_result(request_id, result)

    log_message = "LLM error: #{error.error_type} - #{error.message}"
    log_message += " | response_body: #{response_body}" if response_body
    Sidekiq.logger.error(log_message)
  end
end
