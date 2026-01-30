# frozen_string_literal: true

require "json"

class ChatAction
  def call(env)
    request = Rack::Request.new(env)
    params = JSON.parse(request.body.read)

    user_message = params["message"]
    if user_message.nil? || user_message.strip.empty?
      return [400, {"content-type" => "application/json"}, [{error: "Message is required"}.to_json]]
    end

    # Load existing chat or create new one
    chat = if params["chat"]
      Sidekiq::AsyncLlm::Chat.load(params["chat"])
    else
      Sidekiq::AsyncLlm::Chat.new(
        completion_worker: LlmCompletionWorker,
        error_worker: LlmErrorWorker,
        model: params["model"],
        provider: "openai", # LM Studio is OpenAI-compatible
        api_base: params["api_base"]
      )
    end

    # Apply settings via builder methods
    if params["system_prompt"] && !params["system_prompt"].empty?
      chat.with_instructions(params["system_prompt"], replace: true)
    end

    if params["temperature"]
      chat.with_temperature(params["temperature"].to_f)
    end

    if params["thinking_enabled"]
      chat.with_thinking(
        effort: params["thinking_effort"],
        budget: params["thinking_budget"]&.to_i
      )
    end

    if params["schema"] && !params["schema"].empty?
      begin
        schema = JSON.parse(params["schema"])
        chat.with_schema(schema)
      rescue JSON::ParserError
        # Ignore invalid schema
      end
    end

    if params["max_tokens"] && params["max_tokens"].to_i > 0
      chat.with_params(max_tokens: params["max_tokens"].to_i)
    end

    # Either call from Sidekiq worker or directly
    if params["call_from_sidekiq"]
      ChatRequestWorker.perform_async(chat.as_json, user_message)
    else
      chat.ask(user_message)
    end

    [202, {"content-type" => "application/json"}, [{status: "accepted"}.to_json]]
  rescue JSON::ParserError => e
    [400, {"content-type" => "application/json"}, [{error: "Invalid JSON: #{e.message}"}.to_json]]
  end
end
