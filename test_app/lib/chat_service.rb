# frozen_string_literal: true

class ChatService
  RESULT_KEY_PREFIX = "llm_result:"
  RESULT_TTL = 30

  class << self
    # Store a result for a specific request ID
    #
    # @param request_id [String] the request identifier
    # @param result [Hash] the result data to store
    # @param total_duration [Float] the total duration of the request
    def set_result(request_id, result, total_duration)
      update_result_hash(request_id, payload: result, total_duration: total_duration)
    end

    # Retrieve and delete a result for a specific request ID
    #
    # @param request_id [String] the request identifier
    # @return [Hash, nil] the result data or nil if not found
    def get_result(request_id)
      json = result_value(request_id, "payload")
      return nil unless json

      durations = Array(result_value(request_id, "durations")&.split(",")).map(&:to_f)

      payload = JSON.parse(json)
      payload["http_duration"] = durations.sum
      payload["request_count"] = durations.size
      payload["total_duration"] = result_value(request_id, "total_duration").to_f

      delete_result(request_id)

      payload
    end

    def record_request_duration(request_id, duration)
      durations = Sidekiq.redis { |conn| conn.hget(result_key(request_id), "durations") }
      durations = durations ? durations.split(",") : []
      durations << duration.round(6).to_s
      update_result_hash(request_id, durations: durations.join(","))
    end

    private

    def result_key(request_id)
      "#{RESULT_KEY_PREFIX}#{request_id}"
    end

    def update_result_hash(request_id, values)
      key = result_key(request_id)

      redis_values = {}
      values.each do |k, v|
        redis_values[k.to_s] = v.is_a?(Hash) ? JSON.generate(v) : v&.to_s
      end

      Sidekiq.redis do |conn|
        conn.multi do |transaction|
          transaction.hset(key, redis_values)
          transaction.expire(key, RESULT_TTL)
        end
      end
    end

    def result_value(request_id, field)
      Sidekiq.redis { |conn| conn.hget(result_key(request_id), field) }
    end

    def delete_result(request_id)
      Sidekiq.redis { |conn| conn.del(result_key(request_id)) }
    end
  end
end
