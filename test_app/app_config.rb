# frozen_string_literal: true

class AppConfig
  class << self
    def redis_url
      ENV.fetch("REDIS_URL", "redis://localhost:23450/1")
    end

    def max_connections
      ENV.fetch("MAX_CONNECTIONS", 100).to_i
    end

    def sidekiq_concurrency
      ENV.fetch("SIDEKIQ_CONCURRENCY", 10).to_i
    end

    def port
      ENV.fetch("PORT", 9393).to_i
    end

    # LM Studio compatible API endpoint
    def llm_api_base
      ENV.fetch("LLM_API_BASE", "http://localhost:1234")
    end

    # Default model to use (LM Studio serves models at this endpoint)
    def default_model
      ENV.fetch("LLM_MODEL", "local-model")
    end
  end
end
