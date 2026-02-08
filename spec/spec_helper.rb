# frozen_string_literal: true

require "bundler/setup"

require_relative "../lib/sidekiq-async_llm"

# Mock callback class for testing
class TestCallback
  def on_complete(chat, message, callback_args, response)
  end

  def on_error(chat, callback_args, error)
  end
end

# Configure RubyLLM with fake API keys for testing
RubyLLM.configure do |config|
  config.openai_api_key = "test-key"
  config.anthropic_api_key = "test-key"
end

Sidekiq.logger.level = Logger::ERROR if Sidekiq.respond_to?(:logger) && Sidekiq.logger

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
