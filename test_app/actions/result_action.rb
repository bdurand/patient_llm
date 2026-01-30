# frozen_string_literal: true

require "json"

class ResultAction
  def call(env)
    result = ChatService.get_result

    if result
      ChatService.clear_result
      [200, {"content-type" => "application/json"}, [result.to_json]]
    else
      [204, {}, []]
    end
  end
end
