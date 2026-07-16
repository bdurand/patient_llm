# frozen_string_literal: true

require "json"
require "net/http"

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
    path_override = nil
    serializer_override = nil
    headers_override = nil
    provider = :test
    agent_class = nil

    if provider_name && provider_name != "custom" && PremiumProviders::PROVIDERS.key?(provider_name)
      # Premium providers dispatch through their Agent class so the test app
      # exercises the declarative agent path.
      agent_class = ChatAgent.for_provider(provider_name)
      effective_serializer = PremiumProviders.serializer(provider_name)
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
        path_override = params["api_path"]
        serializer_override = PatientLLM::SERIALIZER_PATHS.key(path_override.sub(%r{\A/}, ""))
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
      session.system = params["system_prompt"] || "You are a helpful assistant."
    end

    thinking_enabled = params["thinking_enabled"]

    if params["temperature"] && !(thinking_enabled && effective_serializer == :messages)
      session.temperature = params["temperature"].to_f
    end

    if thinking_enabled
      if effective_serializer == :messages
        # Messages uses an explicit thinking budget
        budget = params["thinking_budget"].to_i
        budget = 10000 if budget < 1
        session.think(budget_tokens: budget)
      else
        # Everything else takes a portable effort level (Converse warns and skips)
        session.think(effort: params["thinking_effort"] || "medium")
      end
    end

    if params["schema"] && !params["schema"].empty?
      begin
        session.json_output(JSON.parse(params["schema"]))
      rescue JSON::ParserError
        # Ignore invalid schema
      end
    end

    if params["max_tokens"] && params["max_tokens"].to_i > 0
      session.max_output_tokens = params["max_tokens"].to_i
    end

    if params["max_output_tokens"] && params["max_output_tokens"].to_i > 0
      session.max_output_tokens = params["max_output_tokens"].to_i
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

    if params["service_tier"] && !params["service_tier"].empty?
      session.service_tier = params["service_tier"]
    end

    if params["metadata"].is_a?(Hash) && !params["metadata"].empty?
      session.metadata = params["metadata"]
    end

    if params["tools_enabled"]
      allowed_tools = params["allowed_tools"]
      if allowed_tools.is_a?(Array) && !allowed_tools.empty?
        known_tools = allowed_tools.select { |name| PromptBuilder.tool_registry.definition_for(name) }
        session.use_tools(*known_tools) unless known_tools.empty?
      else
        session.use_tools
      end
    end

    # Build the user message content (with optional attachments)
    message_content = user_message
    file_attachments = params["attachments"]
    if file_attachments.is_a?(Array) && !file_attachments.empty?
      content = []
      content << {"type" => "input_text", "text" => user_message} unless user_message.empty?
      file_attachments.each do |attachment|
        if attachment["url"]
          media_type = resolve_url_content_type(attachment["url"])
          if media_type&.start_with?("image/")
            content << {"type" => "input_image", "url" => attachment["url"], "media_type" => media_type}
          else
            entry = {"type" => "input_file", "url" => attachment["url"]}
            entry["media_type"] = media_type if media_type
            content << entry
          end
        else
          media_type = attachment["media_type"].to_s
          if media_type.start_with?("image/")
            content << {"type" => "input_image", "url" => "data:#{media_type};base64,#{attachment["data"]}"}
          else
            entry = {"type" => "input_file", "url" => "data:#{media_type};base64,#{attachment["data"]}"}
            entry["filename"] = attachment["name"] if attachment["name"]
            content << entry
          end
        end
      end
      message_content = content
    end

    request_id = SecureRandom.uuid

    if agent_class
      # The agent adds the message, dispatches with its declared provider, and
      # handles the response through its completed/failed/tool_round hooks.
      # Tool calls are executed by the agent's instance methods.
      agent_class.ask(
        message_content,
        session: session,
        context: {request_id: request_id, start_time: Time.now.to_f}
      )
    else
      session.user(message_content)

      PatientLLM.ask(
        session,
        provider: provider,
        callback: LLMCallback,
        callback_args: {request_id: request_id, start_time: Time.now.to_f},
        url: url_override,
        serializer: serializer_override,
        path: path_override,
        headers: headers_override
      )
    end

    [202, {"content-type" => "application/json"}, [{status: "accepted", request_id: request_id}.to_json]]
  rescue PromptBuilder::UnsupportedFormatError => e
    [400, {"content-type" => "application/json"}, [{error: e.message}.to_json]]
  rescue JSON::ParserError => e
    [400, {"content-type" => "application/json"}, [{error: "Invalid JSON: #{e.message}"}.to_json]]
  end

  private

  def resolve_url_content_type(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 5
    http.read_timeout = 5
    response = http.head(uri.request_uri)
    response["content-type"]&.split(";")&.first&.strip
  rescue
    nil
  end
end
