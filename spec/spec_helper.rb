# frozen_string_literal: true

# Suppress the IO::Buffer experimental warning triggered by io-event (via async-http)
Warning[:experimental] = false

require "bundler/setup"

# SimpleCov must be started before requiring the lib
begin
  require "simplecov"
  SimpleCov.start do
    add_filter "/spec/"
    enable_coverage :branch
  end
rescue LoadError
  # SimpleCov is not available
end

Bundler.require(:default, :test)

require "webmock/rspec"

require_relative "../lib/patient_llm"

# Mock callback class for testing
class TestCallback
  def on_complete(session:, provider:, llm_response:, callback_args:, http_response:, request_id:)
  end

  def on_error(session:, provider:, callback_args:, error:, http_response:, request_id:)
  end
end

# Register the test secret so inline execution can resolve it
PatientHttp.register_secret("openai.api_key", "test-api-key")

# Configure a test provider
PatientLLM.configure do |config|
  config.provider :openai,
    url: "https://api.openai.com",
    headers: {"Authorization" => PatientHttp.secret("openai.api_key")},
    serializer: :chat_completion
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
