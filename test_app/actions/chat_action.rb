# frozen_string_literal: true

require 'json'

class ChatAction
  def call(env)
    request = Rack::Request.new(env)
    params = JSON.parse(request.body.read)

    user_message = params['message']
    if user_message.nil? || user_message.strip.empty?
      return [400, { 'content-type' => 'application/json' }, [{ error: 'Message is required' }.to_json]]
    end

    api_url = params['api_url']
    api_base = nil
    completion_path = nil
    if api_url
      uri = URI.parse(api_url)
      completion_path = uri.path
      uri.path = ''
      api_base = uri.to_s
    end

    # Load existing chat or create new one
    chat = if params['chat']
             PatientHttp::LLM::Chat.load(params['chat'])
           else
             PatientHttp::LLM::Chat.new(
               callback: LLMCallback,
               model: params['model'],
               provider: 'openai', # LM Studio is OpenAI-compatible
               api_base: api_base,
               completion_path: completion_path,
               tools: [WeatherTool, CalculatorTool]
             )
           end

    # Apply settings via builder methods
    if params['system_prompt'] && !params['system_prompt'].empty?
      chat.with_instructions(params['system_prompt'], replace: true)
    end

    chat.with_temperature(params['temperature'].to_f) if params['temperature']

    if params['thinking_enabled']
      chat.with_thinking(
        effort: params['thinking_effort'],
        budget: params['thinking_budget']&.to_i
      )
    end

    if params['schema'] && !params['schema'].empty?
      begin
        schema = JSON.parse(params['schema'])
        chat.with_schema(schema)
      rescue JSON::ParserError
        # Ignore invalid schema
      end
    end

    chat.with_params(max_tokens: params['max_tokens'].to_i) if params['max_tokens'] && params['max_tokens'].to_i > 0

    request_id = chat.ask(user_message)

    [202, { 'content-type' => 'application/json' }, [{ status: 'accepted', request_id: request_id }.to_json]]
  rescue JSON::ParserError => e
    [400, { 'content-type' => 'application/json' }, [{ error: "Invalid JSON: #{e.message}" }.to_json]]
  end
end
