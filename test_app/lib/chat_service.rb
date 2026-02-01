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
  end
end
