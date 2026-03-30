# frozen_string_literal: true

require "json"

module PatientHttp
  module LLM
    # Builds OpenAI Chat Completions API request payloads.
    module PayloadBuilder
      class << self
        # Build a request payload for the OpenAI Chat Completions API.
        #
        # @param messages [Array<Hash>] Conversation messages
        # @param model [String] Model identifier
        # @param tools [Array, nil] Tool instances
        # @param temperature [Float, nil] Temperature value
        # @param schema [Hash, nil] JSON schema for structured output
        # @param thinking [Hash, nil] Thinking configuration with :effort and/or :budget keys
        # @return [Hash]
        def build(messages:, model:, tools: nil, temperature: nil, schema: nil, thinking: nil)
          payload = {model: model}

          payload[:messages] = messages.map { |m| build_message(m) }

          if tools && !tools.empty?
            payload[:tools] = tools.map { |t| build_tool(t) }
          end

          payload[:temperature] = temperature if temperature

          if schema
            payload[:response_format] = {
              type: "json_schema",
              json_schema: {name: "response", schema: schema}
            }
          end

          if thinking
            payload[:reasoning_effort] = thinking[:effort] if thinking[:effort]
            payload[:max_completion_tokens] = thinking[:budget] if thinking[:budget]
          end

          payload
        end

        private

        def build_message(message)
          msg = {role: message[:role].to_s}
          msg[:content] = message[:content] if message[:content]
          msg[:tool_call_id] = message[:tool_call_id] if message[:tool_call_id]

          if message[:tool_calls] && !message[:tool_calls].empty?
            msg[:tool_calls] = message[:tool_calls].map do |id, tc|
              {
                id: id,
                type: "function",
                function: {
                  name: tc[:name] || tc["name"],
                  arguments: (tc[:arguments] || tc["arguments"]).to_json
                }
              }
            end
          end

          msg
        end

        def build_tool(tool)
          {
            type: "function",
            function: {
              name: tool.name,
              description: tool.description,
              parameters: tool.parameters
            }
          }
        end
      end
    end
  end
end
