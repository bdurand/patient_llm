# frozen_string_literal: true

require "bundler/setup"

require_relative "../lib/patient_llm"

# Mock callback class for testing
class TestCallback
  def on_complete(session:, provider:, llm_response:, callback_args:, http_response:, request_id:)
  end

  def on_error(session:, provider:, callback_args:, error:, http_response:, request_id:)
  end
end

# Configure a test provider
PatientLLM.configure do |config|
  config.provider :openai,
    url: "https://api.openai.com",
    headers: {"Authorization" => "Bearer test-key"},
    serializer: :chat_completion
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
