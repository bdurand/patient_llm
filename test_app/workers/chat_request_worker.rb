# frozen_string_literal: true

class ChatRequestWorker
  include Sidekiq::Job

  def perform(chat_json, user_message)
    chat = Sidekiq::AsyncLLM::Chat.load(chat_json)
    chat.ask(user_message)

    puts JSON.pretty_generate(chat.as_json)
    Sidekiq.logger.info("Chat request enqueued: #{user_message.slice(0, 100)}...")
  end
end
