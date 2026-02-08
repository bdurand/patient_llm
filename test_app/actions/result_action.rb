# frozen_string_literal: true

require "json"

class ResultAction
  def call(env)
    request = Rack::Request.new(env)
    request_id = request.params["request_id"]

    return [400, {"content-type" => "application/json"}, [{error: "request_id is required"}.to_json]] unless request_id

    result = ChatService.get_result(request_id)

    if result
      [200, {"content-type" => "application/json"}, [result.to_json]]
    else
      [204, {}, []]
    end
  end
end
