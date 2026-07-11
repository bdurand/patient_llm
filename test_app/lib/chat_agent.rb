# frozen_string_literal: true

require_relative "premium_providers"

# Declarative agent used for chats with the premium providers. The web UI
# still drives the per-request session settings (model, system prompt,
# temperature, etc.), so this class deliberately leaves those undeclared;
# what it exercises is the agent path itself: the provider declaration, tool
# schemas declared with the DSL and handled by instance methods, context
# passing, and the completed/failed/tool_round hooks. One subclass per
# premium provider gives each a resolvable class name to travel through the
# job queue as the callback identity.
#
# The declared models make the agents usable directly from the console too:
#
#   OpenAIChatAgent.ask!("What is the weather in Chicago?").text
class ChatAgent < PatientLLM::Agent
  tool :weather, "Get weather forecast for a city" do
    param :city, :string, "Name of the city", required: true
    param :state, :string, "State or province"
    param :country, :string, "Country"
  end

  tool :traffic_conditions, "Get current or anticipated traffic conditions for a city" do
    param :city, :string, "Name of the city", required: true
    param :state, :string, "State or province"
    param :country, :string, "Country"
    param :time, :string, "Time of day to check traffic (e.g. '8:00 AM', 'rush hour')"
  end

  class << self
    # Look up the agent class for a premium provider name.
    #
    # @param provider_name [String] the provider identifier
    # @return [Class] the ChatAgent subclass for the provider
    def for_provider(provider_name)
      AGENTS.fetch(provider_name.to_s) do
        raise ArgumentError, "No agent class registered for provider #{provider_name.inspect}"
      end
    end
  end

  def weather(city:, state: nil, country: nil)
    WeatherTool.call(city: city, state: state, country: country)
  end

  def traffic_conditions(city:, state: nil, country: nil, time: nil)
    TrafficConditionsTool.call(city: city, state: state, country: country, time: time)
  end

  # Store the final response where the web UI polls for it.
  def completed(response, context)
    message = {
      role: "assistant",
      content: response.text,
      model_id: response.model,
      input_tokens: response.usage&.input_tokens,
      output_tokens: response.usage&.output_tokens,
      duration: last_http_response.duration&.round(1)
    }

    text_format = session.text&.dig("format", "type")
    message[:structured] = true if text_format == "json_schema"

    result = {
      success: true,
      message: message,
      session: response.state,
      timestamp: Time.now.iso8601
    }

    ChatService.record_request_duration(context[:request_id], last_http_response.duration)
    store_result(result, context)

    Sidekiq.logger.info("#{self.class.name} completion stored: #{response.text&.slice(0, 100)}...")
  end

  # Record each automatic tool round so the UI can show the request count and
  # cumulative HTTP duration.
  def tool_round(response, context)
    ChatService.record_request_duration(context[:request_id], last_http_response.duration)
    Sidekiq.logger.info("#{self.class.name} executed tools: #{response.tool_calls.map(&:name).join(", ")}")
  end

  # Store the error where the web UI polls for it.
  def failed(error, context)
    result = {
      success: false,
      error: {
        type: error.error_type.to_s,
        message: error.message,
        error_class: error.error_class
      },
      session: session.to_h,
      timestamp: Time.now.iso8601
    }

    # last_http_response is nil for transport errors (timeouts, connection failures)
    if last_http_response
      if last_http_response.json?
        begin
          result[:error][:details] = last_http_response.json
        rescue JSON::ParserError
          # Ignore JSON parsing errors in the error response
        end
      end

      if last_http_response.json? || last_http_response.content_type.to_s.downcase.include?("text/plain")
        response_body = last_http_response.body
      end

      ChatService.record_request_duration(context[:request_id], last_http_response.duration)
    end

    store_result(result, context)

    log_message = "#{self.class.name} error: #{error.error_type} - #{error.message}"
    log_message += " | response_body: #{response_body}" if response_body
    Sidekiq.logger.error(log_message)
  end

  private

  def store_result(result, context)
    total_duration = Time.now.to_f - context[:start_time].to_f if context[:start_time]
    ChatService.set_result(context[:request_id], result, total_duration)
  end
end

class OpenAIChatAgent < ChatAgent
  provider :openai
  model PremiumProviders::PROVIDERS["openai"][:default_model]
end

class AnthropicChatAgent < ChatAgent
  provider :anthropic
  model PremiumProviders::PROVIDERS["anthropic"][:default_model]
end

class GeminiChatAgent < ChatAgent
  provider :gemini
  model PremiumProviders::PROVIDERS["gemini"][:default_model]
end

class BedrockChatAgent < ChatAgent
  provider :bedrock
  model PremiumProviders::PROVIDERS["bedrock"][:default_model]
end

ChatAgent::AGENTS = {
  "openai" => OpenAIChatAgent,
  "anthropic" => AnthropicChatAgent,
  "gemini" => GeminiChatAgent,
  "bedrock" => BedrockChatAgent
}.freeze
