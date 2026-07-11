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

# Configure LLM providers. Presets supply each vendor's URL, serializer, auth
# header, and key format; api_key registers the key with PatientHttp so no
# separate register_secret step is needed.
PatientLLM.configure do |config|
  config.provider :test,
    url: AppConfig.llm_api_base,
    serializer: :chat_completion,
    headers: {}

  PremiumProviders.available.each_key do |name|
    if name == "bedrock"
      region = ENV.fetch("BEDROCK_REGION", "us-east-1")
      if PremiumProviders.bedrock_sigv4?
        config.provider :bedrock, preset: :bedrock, region: region, preprocessors: :aws_sigv4
      else
        config.provider :bedrock, preset: :bedrock, region: region, api_key: PremiumProviders.api_key(name)
      end
    else
      config.provider name.to_sym, preset: name.to_sym, api_key: PremiumProviders.api_key(name)
    end
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
    # Agent requests carry the request id inside the agent context; the
    # LLMCallback path passes it at the top level.
    agent_context = error.callback_args[:context] || {}
    request_id = error.callback_args[:request_id] || agent_context["request_id"]
    start_time = error.callback_args[:start_time] || agent_context["start_time"]
    total_duration = Time.now.to_f - start_time if start_time
    ChatService.set_result(request_id, result, total_duration)
  end

  if PremiumProviders.bedrock_sigv4?
    config.register_preprocessor(:aws_sigv4, PatientLLM::AwsRequestSigner.new(
      credentials: Aws::CredentialProviderChain.new
    ))
  end
end

# Surface any wiring mistakes (missing secrets, preprocessors, or handlers) at
# boot instead of at dispatch time inside a job.
PatientLLM.verify_configuration!

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
