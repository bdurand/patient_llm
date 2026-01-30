# frozen_string_literal: true

require "bundler/setup"

require_relative "../lib/sidekiq-async_llm"

# Configure RubyLLM with fake API keys for testing
RubyLLM.configure do |config|
  config.openai_api_key = "test-key"
  config.anthropic_api_key = "test-key"
end

# Mock worker classes for testing
class TestCompletionWorker
  include Sidekiq::Job if defined?(Sidekiq::Job)

  def perform(chat, response)
  end
end

class TestErrorWorker
  include Sidekiq::Job if defined?(Sidekiq::Job)

  def perform(chat, error)
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
