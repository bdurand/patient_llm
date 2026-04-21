# frozen_string_literal: true

require "json"

module PatientHttp
  module LLM
    # Parses OpenAI Chat Completions API responses into Message objects.
    module ResponseParser
      class << self
        # Parse an OpenAI Chat Completions API response body.
        #
        # @param body [Hash] Parsed JSON response body
        # @return [Message]
        def parse(body)
          choice = body.dig("choices", 0, "message") || {}
          usage = body["usage"] || {}

          tool_calls = parse_tool_calls(choice["tool_calls"])

          Message.new(
            role: choice["role"] || "assistant",
            content: choice["content"],
            tool_calls: tool_calls,
            model_id: body["model"],
            input_tokens: usage["prompt_tokens"],
            output_tokens: usage["completion_tokens"]
          )
        end

        private

        def parse_tool_calls(raw_tool_calls)
          return {} unless raw_tool_calls&.any?

          raw_tool_calls.each_with_object({}) do |tc, hash|
            id = tc["id"]
            args = tc.dig("function", "arguments")
            parsed_args = parse_arguments(args)

            hash[id] = ToolCall.new(
              id: id,
              name: tc.dig("function", "name"),
              arguments: parsed_args
            )
          end
        end

        def parse_arguments(args)
          return {} if args.nil? || args == ""

          parsed = JSON.parse(args)
          parsed.is_a?(Hash) ? parsed.transform_keys(&:to_sym) : parsed
        rescue JSON::ParserError
          # Model emitted non-JSON arguments; hand back the raw string so the
          # tool executor can decide how to handle it.
          args
        end
      end
    end
  end
end
