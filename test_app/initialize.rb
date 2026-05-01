# frozen_string_literal: true

require "bundler/setup"
Bundler.require

require "sidekiq"
require "patient_llm"

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
PatientLLM.configure do |config|
  config.provider :test,
    url: AppConfig.llm_api_base,
    headers: {}
end

PatientHttp::Sidekiq.configure do |config|
  config.request_timeout = 120
end

# Register tools
PromptBuilder.tool_registry.register(
  "weather",
  description: "Get weather forecast for a city",
  parameters: {
    type: "object",
    properties: {
      city: {type: "string", description: "Name of the city"},
      state: {type: "string", description: "State or province"},
      country: {type: "string", description: "Country"}
    },
    required: ["city"]
  }
) do |args|
  WeatherTool.call(**args.transform_keys(&:to_sym))
end

PromptBuilder.tool_registry.register(
  "traffic_conditions",
  description: "Get current or anticipated traffic conditions for a city",
  parameters: {
    type: "object",
    properties: {
      city: {type: "string", description: "Name of the city"},
      state: {type: "string", description: "State or province"},
      country: {type: "string", description: "Country"},
      time: {type: "string", description: "Time of day to check traffic (e.g. '8:00 AM', 'rush hour')"}
    },
    required: ["city"]
  }
) do |args|
  TrafficConditionsTool.call(**args.transform_keys(&:to_sym))
end

puts "Initialized with:"
puts "  Redis: #{AppConfig.redis_url}"
puts "  LLM API: #{AppConfig.llm_api_base}"
puts "  Default Model: #{AppConfig.default_model}"
puts "  Port: #{AppConfig.port}"
