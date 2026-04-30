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

    api_url = params["api_url"]
    url_override = nil
    completion_path_override = nil
    serializer_override = nil

    if api_url
      uri = URI.parse(api_url)
      # Strip any path from the base URL
      uri.path = ""
      url_override = uri.to_s
    end

    if params["api_path"] && !params["api_path"].empty?
      completion_path_override = params["api_path"]
      serializer_override = PatientHttp::LLM::SERIALIZER_PATHS.key(completion_path_override)
    end

    # Load existing session or create new one
    session = if params["session"]
      PromptBuilder::Session.from_h(params["session"])
    else
      PromptBuilder::Session.new(model: params["model"])
    end

    # Apply settings
    if params["system_prompt"] && !params["system_prompt"].empty?
      session.instructions = params["system_prompt"] || "You are a helpful assistant."
    end

    if params["temperature"]
      session.temperature = params["temperature"].to_f
    end

    if params["thinking_enabled"]
      reasoning = {effort: params["thinking_effort"] || "medium"}
      reasoning[:budget_tokens] = params["thinking_budget"].to_i if params["thinking_budget"]
      session.reasoning = reasoning
    end

    if params["schema"] && !params["schema"].empty?
      begin
        schema = JSON.parse(params["schema"])
        session.text = {
          format: {
            type: "json_schema",
            json_schema: {name: "response", schema: schema}
          }
        }
      rescue JSON::ParserError
        # Ignore invalid schema
      end
    end

    if params["max_tokens"] && params["max_tokens"].to_i > 0
      session.max_output_tokens = params["max_tokens"].to_i
    end

    session.register_tools(PromptBuilder.tool_registry)

    # Add the user message
    session.user(user_message)

    request_id = PatientHttp::LLM.ask(
      session,
      provider: :openai,
      callback: LLMCallback,
      url: url_override,
      serializer: serializer_override,
      completion_path: completion_path_override
    )

    [202, {"content-type" => "application/json"}, [{status: "accepted", request_id: request_id}.to_json]]
  rescue JSON::ParserError => e
    [400, {"content-type" => "application/json"}, [{error: "Invalid JSON: #{e.message}"}.to_json]]
  end
end
