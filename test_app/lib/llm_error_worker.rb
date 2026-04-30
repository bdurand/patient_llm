# frozen_string_literal: true

class LLMErrorWorker
  include Sidekiq::Job

  def perform(error, session, callback_args)
    # session is a PromptBuilder::Session (deserialized)
    # error is the error details

    # Build error result payload
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

    ChatService.set_result(result)
    Sidekiq.logger.error("LLM error: #{error.error_type} - #{error.message}")
  end
end
