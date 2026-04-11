# frozen_string_literal: true

require "bundler/setup"

require_relative "../lib/patient_http-llm"

# Mock callback class for testing
class TestCallback
  def on_complete(chat, message, callback_args, response)
  end

  def on_error(chat, callback_args, error)
  end
end

# Configure a test provider
PatientHttp::LLM.configure do |config|
  config.provider :openai,
    url: "https://api.openai.com",
    headers: {"Authorization" => "Bearer test-key"}
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
