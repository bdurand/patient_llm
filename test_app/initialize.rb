# frozen_string_literal: true

require "bundler/setup"
Bundler.require

require "dotenv/load"
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

  # Register premium providers whose API keys are present
  PremiumProviders.available.each do |name, provider_config|
    config.provider name.to_sym,
      url: PremiumProviders.base_url(name),
      headers: PremiumProviders.auth_header(name),
      serializer: provider_config[:serializer]
  end
end

PatientHttp::Sidekiq.configure do |config|
  config.request_timeout = 120
  config.encryption_key = "supersecretkeyfortesting"
  config.sidekiq_options = {retry_count: 1}

  config.on_retries_exhausted do |error|
    result = {
      success: false,
      error: {
        type: error.error_type.to_s,
        message: error.message,
        error_class: error.error_class
      },
      timestamp: Time.now.iso8601
    }
    request_id = error.callback_args[:request_id]
    start_time = error.callback_args[:start_time]
    total_duration = Time.now.to_f - start_time if start_time
    ChatService.set_result(request_id, result, total_duration)
  end

  PremiumProviders.available.each_key do |name|
    config.register_secret("#{name}.api_key") { PremiumProviders.auth_header_value(name) }
  end
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
