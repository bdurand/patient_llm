# frozen_string_literal: true

require "json"

class ResetAction
  def call(env)
    ChatService.clear_result

    [200, {"content-type" => "application/json"}, [{status: "reset"}.to_json]]
  end
end
