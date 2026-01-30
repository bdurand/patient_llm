# frozen_string_literal: true

require "bundler/setup"
Bundler.require

require "sidekiq"
require "sidekiq/async_http"
require "sidekiq-async_llm"
require "json"

require_relative "app_config"
require_relative "chat_service"

# Load workers
Dir[File.join(__dir__, "workers", "*.rb")].each { |f| require f }

# Configure Sidekiq
Sidekiq.configure_server do |config|
  config.redis = {url: AppConfig.redis_url}
  config.concurrency = AppConfig.sidekiq_concurrency

  # Add server middleware directly
  config.server_middleware do |chain|
    chain.add Sidekiq::AsyncHttp::Context::Middleware
    chain.add Sidekiq::AsyncHttp::ContinuationMiddleware
    chain.add Sidekiq::AsyncLlm::Middleware
  end

  # Add client middleware for serialization
  config.client_middleware do |chain|
    chain.prepend Sidekiq::AsyncHttp::SerializeResponseMiddleware
  end
end

Sidekiq.configure_client do |config|
  config.redis = {url: AppConfig.redis_url}
  config.client_middleware do |chain|
    chain.prepend Sidekiq::AsyncHttp::SerializeResponseMiddleware
  end
end

# Configure AsyncHttp processor
Sidekiq::AsyncHttp.configure do |config|
  config.max_connections = AppConfig.max_connections
  config.default_request_timeout = 300 # 5 minutes for LLM responses
end

# Configure RubyLLM for local LM Studio
# LM Studio provides an OpenAI-compatible API
RubyLLM.configure do |config|
  config.openai_api_key = "lm-studio" # LM Studio doesn't require a real key
end

puts "Initialized with:"
puts "  Redis: #{AppConfig.redis_url}"
puts "  LLM API: #{AppConfig.llm_api_base}"
puts "  Default Model: #{AppConfig.default_model}"
puts "  Port: #{AppConfig.port}"
