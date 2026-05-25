# frozen_string_literal: true

require "json"

class ChatAction
  def call(env)
    request = Rack::Request.new(env)
    params = JSON.parse(request.body.read)

    user_message = params["message"].to_s.strip
    has_attachments = params["attachments"].is_a?(Array) && !params["attachments"].empty?
    if user_message.empty? && !has_attachments
      return [400, {"content-type" => "application/json"}, [{error: "Message is required"}.to_json]]
    end

    api_url = params["api_url"]
    provider_name = params["provider"]
    url_override = nil
    completion_path_override = nil
    serializer_override = nil
    headers_override = nil
    provider = :test

    if provider_name && provider_name != "custom" && PremiumProviders::PROVIDERS.key?(provider_name)
      provider = provider_name.to_sym
      model = params["model"].to_s
      completion_path_override = PremiumProviders.completion_path(provider_name, model)
      effective_serializer = PremiumProviders::PROVIDERS[provider_name][:serializer]
    else
      if api_url
        uri = URI.parse(api_url)
        # Strip any path from the base URL
        uri.path = ""
        url_override = uri.to_s
      end

      authorization = params["authorization"].to_s.strip
      unless authorization.empty?
        header_name, header_value = authorization.split(":", 2).map(&:strip)
        if header_name&.match?(/\A[A-Za-z0-9-]+\z/) && header_value && !header_value.empty?
          headers_override = {header_name => header_value}
        end
      end

      if params["api_path"] && !params["api_path"].empty?
        completion_path_override = params["api_path"]
        serializer_override = PatientLLM::SERIALIZER_PATHS.key(completion_path_override)
      end

      effective_serializer = serializer_override
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

    thinking_enabled = params["thinking_enabled"]

    if params["temperature"] && !(thinking_enabled && effective_serializer == :messages)
      session.temperature = params["temperature"].to_f
    end

    if thinking_enabled
      case effective_serializer
      when :converse
        # Converse does not support reasoning; skip
      when :chat_completion, :open_responses, :gemini
        # These serializers only support effort
        session.reasoning = {effort: params["thinking_effort"] || "medium"}
      when :messages
        # Messages requires budget_tokens and max_output_tokens > budget_tokens
        budget = params["thinking_budget"].to_i
        budget = 10000 if budget < 1
        session.reasoning = {budget_tokens: budget}
      else
        session.reasoning = {effort: params["thinking_effort"] || "medium"}
      end
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

    # Anthropic requires max_tokens > budget_tokens when thinking is enabled
    if thinking_enabled && effective_serializer == :messages
      budget = session.reasoning&.fetch("budget_tokens", 0) || 0
      max_tokens = session.max_output_tokens || 0
      session.max_output_tokens = budget + 4096 if max_tokens < budget + 1
    end

    if params["top_p"] && !(thinking_enabled && effective_serializer == :messages)
      session.top_p = params["top_p"].to_f
    end

    if params["presence_penalty"]
      session.presence_penalty = params["presence_penalty"].to_f
    end

    if params["frequency_penalty"]
      session.frequency_penalty = params["frequency_penalty"].to_f
    end

    if params["top_logprobs"] && params["top_logprobs"].to_i > 0
      session.top_logprobs = params["top_logprobs"].to_i
    end

    if params["tool_choice"] && !params["tool_choice"].empty?
      session.tool_choice = params["tool_choice"]
    end

    if params["parallel_tool_calls"]
      session.parallel_tool_calls = true
    end

    if params["max_tool_calls"] && params["max_tool_calls"].to_i > 0
      session.max_tool_calls = params["max_tool_calls"].to_i
    end

    if params["truncation"] && !params["truncation"].empty?
      session.truncation = params["truncation"]
    end

    if params["store"]
      session.store = true
    end

    if params["service_tier"] && !params["service_tier"].empty?
      session.service_tier = params["service_tier"]
    end

    if params["include"].is_a?(Array) && !params["include"].empty?
      session.include = params["include"]
    end

    if params["safety_identifier"] && !params["safety_identifier"].empty?
      session.safety_identifier = params["safety_identifier"]
    end

    if params["prompt_cache_key"] && !params["prompt_cache_key"].empty?
      session.prompt_cache_key = params["prompt_cache_key"]
    end

    if params["metadata"].is_a?(Hash) && !params["metadata"].empty?
      session.metadata = params["metadata"]
    end

    if params["tools_enabled"]
      allowed_tools = params["allowed_tools"]
      if allowed_tools.is_a?(Array) && !allowed_tools.empty?
        allowed_tools.each do |tool_name|
          definition = PromptBuilder.tool_registry.definition_for(tool_name)
          session.register_tool(definition.name, description: definition.description, parameters: definition.parameters, strict: definition.strict) if definition
        end
      else
        session.register_tools(PromptBuilder.tool_registry)
      end
    end

    # Add the user message (with optional attachments)
    file_attachments = params["attachments"]
    if file_attachments.is_a?(Array) && !file_attachments.empty?
      content = []
      content << {"type" => "input_text", "text" => user_message} unless user_message.empty?
      file_attachments.each do |attachment|
        media_type = attachment["media_type"].to_s
        if media_type.start_with?("image/")
          content << {"type" => "input_image", "image_url" => "data:#{media_type};base64,#{attachment["data"]}"}
        else
          entry = {"type" => "input_file", "file_data" => attachment["data"]}
          entry["filename"] = attachment["name"] if attachment["name"]
          content << entry
        end
      end
      session.user(content)
    else
      session.user(user_message)
    end

    request_id = SecureRandom.uuid

    PatientLLM.ask(
      session,
      provider: provider,
      callback: LLMCallback,
      callback_args: {request_id: request_id},
      url: url_override,
      serializer: serializer_override,
      completion_path: completion_path_override,
      headers: headers_override
    )

    ChatService.record_request_start(request_id)

    [202, {"content-type" => "application/json"}, [{status: "accepted", request_id: request_id}.to_json]]
  rescue PromptBuilder::UnsupportedFormatError => e
    [400, {"content-type" => "application/json"}, [{error: e.message}.to_json]]
  rescue JSON::ParserError => e
    [400, {"content-type" => "application/json"}, [{error: "Invalid JSON: #{e.message}"}.to_json]]
  end
end
