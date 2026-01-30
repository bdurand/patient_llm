# frozen_string_literal: true

class LlmCompletionWorker
  include Sidekiq::Job

  def perform(response, chat, message)
    Sidekiq.logger.info("LlmCompletionWorker received: chat=#{chat.class}, message=#{message.class}")

    # Handle case where middleware didn't process (raw Response object)
    if chat.is_a?(Sidekiq::AsyncHttp::Response)
      response = chat
      Sidekiq.logger.warn("Received raw Response object - middleware may not have processed correctly")
      Sidekiq.logger.info("Response status: #{response.status}")
      Sidekiq.logger.info("Response body (first 500 chars): #{response.body&.slice(0, 500)}")
      return
    end

    # chat is a Sidekiq::AsyncLlm::Chat instance (deserialized by middleware)
    # message is a RubyLLM::Message instance
    # metadata contains duration and other info

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

    ChatService.set_result(result)

    Sidekiq.logger.info("LLM completion stored: #{message.content&.slice(0, 100)}...")
  end
end
