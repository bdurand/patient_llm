# frozen_string_literal: true

class ChatService
  RESULT_KEY = "llm_result"
  RESULT_TTL = 300 # 5 minutes

  class << self
    def set_result(result)
      Sidekiq.redis do |conn|
        conn.set(RESULT_KEY, result.to_json)
        conn.expire(RESULT_KEY, RESULT_TTL)
      end
    end

    def get_result
      Sidekiq.redis do |conn|
        json = conn.get(RESULT_KEY)
        return nil unless json

        conn.del(RESULT_KEY)
        JSON.parse(json)
      end
    end

    def clear_result
      Sidekiq.redis do |conn|
        conn.del(RESULT_KEY)
      end
    end

    def chat(options)
      options = options.transform_keys(&:to_sym)

      chat = Sidekiq::AsyncLlm::Chat.new(
        completion_worker: LlmCompletionWorker,
        error_worker: LlmErrorWorker,
        provider: "openai", # LM Studio is OpenAI-compatible
        api_base: AppConfig.llm_api_base
      )

      # Update model if changed
      if options[:model] && options[:model] != chat.model
        chat.with_model(options[:model])
      end

      # Update api_base if provided
      if options[:api_base] && !options[:api_base].empty?
        chat.with_api_base(options[:api_base])
      end

      # Set system prompt if provided
      if options[:system_prompt] && !options[:system_prompt].empty?
        chat.with_instructions(options[:system_prompt], replace: true)
      end

      # Set temperature if provided
      if options[:temperature]
        chat.with_temperature(options[:temperature].to_f)
      end

      # Set thinking if enabled
      if options[:thinking_enabled]
        effort = options[:thinking_effort] || "medium"
        budget = options[:thinking_budget]&.to_i
        chat.with_thinking(effort: effort, budget: budget)
      else
        chat.with_thinking # Clears thinking
      end

      # Set schema if provided
      if options[:schema] && !options[:schema].empty?
        begin
          schema = JSON.parse(options[:schema])
          chat.with_schema(schema)
        rescue JSON::ParserError
          # Ignore invalid schema
        end
      end

      # Add custom params
      if options[:max_tokens] && options[:max_tokens].to_i > 0
        chat.with_params(max_tokens: options[:max_tokens].to_i)
      end

      chat
    end
  end
end
