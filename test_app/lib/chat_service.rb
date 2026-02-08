# frozen_string_literal: true

class ChatService
  RESULT_KEY_PREFIX = "llm_result:"
  RESULT_TTL = 30

  class << self
    # Store a result for a specific request ID
    #
    # @param request_id [String] the request identifier
    # @param result [Hash] the result data to store
    def set_result(request_id, result)
      Sidekiq.redis do |conn|
        conn.set(result_key(request_id), result.to_json)
        conn.expire(result_key(request_id), RESULT_TTL)
      end
    end

    # Retrieve and delete a result for a specific request ID
    #
    # @param request_id [String] the request identifier
    # @return [Hash, nil] the result data or nil if not found
    def get_result(request_id)
      Sidekiq.redis do |conn|
        json = conn.get(result_key(request_id))
        return nil unless json

        conn.del(result_key(request_id))
        JSON.parse(json)
      end
    end

    private

    def result_key(request_id)
      "#{RESULT_KEY_PREFIX}#{request_id}"
    end
  end
end
