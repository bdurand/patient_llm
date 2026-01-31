# frozen_string_literal: true

class LLMErrorWorker
  include Sidekiq::Job

  def perform(error, chat)
    # chat is a Sidekiq::AsyncLLM::Chat instance (deserialized by middleware)
    # error is a Sidekiq::AsyncLLM::AsyncLLMError instance

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

    ChatService.set_result(result)
    Sidekiq.logger.error("LLM error: #{error.error_type} - #{error.message}")
  end
end
