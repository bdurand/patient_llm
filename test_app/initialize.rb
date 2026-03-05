# frozen_string_literal: true

require "bundler/setup"
Bundler.require

require "sidekiq"
require "patient_http-llm"

require_relative "app_config"

# Load workers
Dir[File.join(__dir__, "lib", "*.rb")].each { |f| require f }

# Configure Sidekiq
Sidekiq.configure_server do |config|
  config.redis = {url: AppConfig.redis_url}
  config.concurrency = AppConfig.sidekiq_concurrency
end

Sidekiq.configure_client do |config|
  config.redis = {url: AppConfig.redis_url}
end

# Configure RubyLLM for local LM Studio
# LM Studio provides an OpenAI-compatible API
RubyLLM.configure do |config|
  config.openai_api_key = "lm-studio" # LM Studio doesn't require a real key
end

PatientHttp.configure do |config|
  config.request_timeout = 120
end

puts "Initialized with:"
puts "  Redis: #{AppConfig.redis_url}"
puts "  LLM API: #{AppConfig.llm_api_base}"
puts "  Default Model: #{AppConfig.default_model}"
puts "  Port: #{AppConfig.port}"
