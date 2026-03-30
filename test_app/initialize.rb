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

# Configure LLM providers
PatientHttp::LLM.configure do |config|
  config.provider :openai,
    url: AppConfig.llm_api_base,
    headers: {}
end

PatientHttp::Sidekiq.configure do |config|
  config.request_timeout = 120
end

puts "Initialized with:"
puts "  Redis: #{AppConfig.redis_url}"
puts "  LLM API: #{AppConfig.llm_api_base}"
puts "  Default Model: #{AppConfig.default_model}"
puts "  Port: #{AppConfig.port}"
