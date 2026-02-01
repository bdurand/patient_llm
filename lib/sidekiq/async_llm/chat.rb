# frozen_string_literal: true

module Sidekiq
  module AsyncLLM
    # Chat is the main interface for making asynchronous LLM requests.
    # It provides a similar interface to RubyLLM::Chat but is designed
    # for async HTTP requests via Sidekiq.
    #
    # @example Basic usage
    #   chat = Sidekiq::AsyncLLM::Chat.new(callback: ChatCallback)
    #   chat.with_instructions("You are a helpful assistant")
    #   chat.add_message(role: :user, content: "Hello!")
    #   chat.ask
    #
    # @example With serialization for multi-turn conversations
    #   # In completion worker:
    #   def perform(chat, response)
    #     chat.add_message(response)
    #     # Save chat.dump for next turn
    #   end
    class Chat
      SERIALIZATION_VERSION = 1

      class << self
        # Deserialize a chat from a JSON hash.
        #
        # @param data [Hash] Serialized chat data
        # @return [Chat]
        def load(data)
          data = data.transform_keys(&:to_s) if data.is_a?(Hash)

          new(
            callback: data["callback"],
            model: data["model"],
            provider: data["provider"],
            api_base: data["api_base"],
            completion_path: data["completion_path"],
            temperature: data["temperature"],
            thinking_effort: data.dig("thinking_effort"),
            thinking_budget: data.dig("thinking_budget"),
            schema: data["schema"],
            params: data["params"],
            headers: data["headers"],
            messages: data["messages"]
          )
        end
      end

      attr_reader :messages, :model, :provider, :temperature, :thinking_effort, :thinking_budget,
        :schema, :params, :headers, :callback, :api_base

      # Initialize a new Chat instance.
      #
      # @param callback [Class, String] The callback instance to handle completion and error events
      # @param model [String, nil] Model identifier (e.g., "gpt-4", "claude-3-opus")
      # @param provider [String, Symbol, nil] Provider identifier (e.g., "openai", "anthropic")
      # @param api_base [String, nil] Override the provider's API base URL (for LM Studio, etc.)
      def initialize(
        callback:,
        model: nil,
        provider: nil,
        api_base: nil,
        completion_path: nil,
        instructions: nil,
        messages: nil,
        temperature: nil,
        thinking_effort: nil,
        thinking_budget: nil,
        schema: nil,
        params: nil,
        headers: nil
      )
        # TODO : validate callback class
        @callback = callback
        @model = model
        @provider = provider&.to_s
        @api_base = api_base
        @completion_path = completion_path
        @messages = []
        @temperature = nil
        @thinking_effort = nil
        @thinking_budget = nil
        @schema = nil
        @params = {}
        @headers = {}

        with_instructions(instructions) if instructions
        add_messages(messages) if messages
        with_temperature(temperature) if temperature
        if thinking_effort || thinking_budget
          with_thinking(effort: thinking_effort, budget: thinking_budget)
        end
        with_schema(schema) if schema
        with_params(params) if params
        with_headers(headers) if headers
      end

      # Set system instructions.
      # System messages are always kept at the top of the messages array.
      #
      # @param instructions [String] The system instructions
      # @param replace [Boolean] If true, replace existing system messages
      # @return [self]
      def with_instructions(instructions, replace: false)
        system_message = {role: :system, content: instructions}

        if replace
          @messages.reject! { |m| m[:role] == :system }
          @messages.unshift(system_message)
        else
          # Find the index after the last system message
          last_system_index = @messages.rindex { |m| m[:role] == :system }
          if last_system_index
            @messages.insert(last_system_index + 1, system_message)
          else
            @messages.unshift(system_message)
          end
        end
        self
      end

      # Set the temperature for generation.
      #
      # @param temperature [Float] Temperature value (0.0-2.0)
      # @return [self]
      def with_temperature(temperature)
        @temperature = temperature
        self
      end

      # Set the model.
      #
      # @param model_id [String] Model identifier
      # @param provider [String, Symbol, nil] Provider identifier
      # @return [self]
      def with_model(model_id, provider: nil)
        @model = model_id
        @provider = provider&.to_s if provider
        self
      end

      # Set a custom API base URL (for LM Studio, Ollama, or other OpenAI-compatible APIs).
      #
      # @param url [String] The API base URL
      # @return [self]
      def with_api_base(url)
        @api_base = url
        self
      end

      # Enable extended thinking mode.
      #
      # @param effort [String, Symbol, nil] Thinking effort level (e.g., "high", "medium", "low")
      # @param budget [Integer, nil] Token budget for thinking
      # @return [self]
      def with_thinking(effort: nil, budget: nil)
        @thinking_effort = effort&.to_s
        @thinking_budget = budget
        self
      end

      def without_thinking
        @thinking_effort = nil
        @thinking_budget = nil
        self
      end

      def thinking
        if @thinking_effort || @thinking_budget
          {effort: @thinking_effort, budget: @thinking_budget}
        end
      end

      # Set a JSON schema for structured output.
      #
      # @param schema [Hash, Object] JSON schema hash or object responding to #to_json_schema
      # @return [self]
      def with_schema(schema)
        @schema = if schema.respond_to?(:to_json_schema)
          schema.to_json_schema[:schema]
        else
          schema
        end
        self
      end

      # Add provider-specific parameters.
      #
      # @param params [Hash] Parameters to merge
      # @return [self]
      def with_params(params)
        @params.merge!(params)
        self
      end

      # Add custom HTTP headers.
      #
      # @param headers [Hash] Headers to merge
      # @return [self]
      def with_headers(headers)
        @headers.merge!(headers)
        self
      end

      def add_messages(messages)
        messages.each do |m|
          add_message(m)
        end
        self
      end

      # Add a message to the conversation.
      #
      # @param message_or_attrs [Hash, RubyLLM::Message, String] Message hash or object
      # @return [self]
      def add_message(message_or_attrs)
        message = if message_or_attrs.is_a?(Hash)
          deserialize_message_hash(message_or_attrs)
        elsif message_or_attrs.respond_to?(:role) && message_or_attrs.respond_to?(:content)
          {role: message_or_attrs.role.to_sym, content: message_or_attrs.content}
        else
          {role: :user, content: message_or_attrs.to_s}
        end

        message[:role] = message[:role].to_sym
        @messages << message
        self
      end

      # Clear all messages.
      #
      # @return [self]
      def reset_messages!
        @messages = []
        self
      end

      # Send a message and make an async LLM request.
      #
      # @param message [String, nil] Optional message to add before asking
      # @param callback_args [Hash] Custom arguments to pass to callback workers
      # @return [Faraday::Response] Placeholder response (202 Accepted)
      def ask(message = nil, callback_args: {})
        add_message(role: :user, content: message) if message

        model_info, provider_instance = resolve_model_and_provider
        payload = build_payload(model_info, provider_instance)

        base_url = api_base || provider_instance.api_base
        request_url = URI.join(base_url, completion_path).to_s
        request_headers = provider_instance.headers.merge(headers)

        Sidekiq::AsyncHttp.post(
          request_url,
          json: payload,
          headers: request_headers,
          raise_error_responses: true,
          callback: Sidekiq::AsyncLLM::Callback,
          callback_args: {
            chat: as_json,
            chat_callback: @callback&.to_s,
            custom: deep_stringify_keys(callback_args)
          }
        )
      end

      # Serialize the chat to a JSON-compatible hash.
      #
      # @return [Hash]
      def as_json
        {
          "v" => SERIALIZATION_VERSION,
          "callback" => @callback&.to_s,
          "model" => model,
          "provider" => provider,
          "api_base" => api_base,
          "completion_path" => completion_path,
          "messages" => messages.map { |m| serialize_message(m) },
          "temperature" => temperature,
          "thinking_effort" => @thinking_effort,
          "thinking_budget" => @thinking_budget,
          "schema" => deep_stringify_keys(schema),
          "params" => deep_stringify_keys(params),
          "headers" => deep_stringify_keys(headers)
        }
      end

      alias_method :dump, :as_json

      def completion_path
        @completion_path || provider_instance.send(:completion_url)
      end

      private

      def deserialize_message_hash(message_hash)
        role = message_hash[:role] || message_hash["role"]
        content = message_hash[:content] || message_hash["content"]

        unless role && content && role != "" && content != ""
          raise ArgumentError.new("Message hash must have role and content; actual keys: #{message_hash.keys.join(", ")}")
        end

        {role: role.to_sym, content: content}
      end

      def resolve_model_and_provider
        RubyLLM::Models.resolve(@model, provider: @provider, assume_exists: true)
      end

      def build_payload(model_info, provider_instance)
        ruby_llm_messages = messages.map { |m| RubyLLM::Message.new(**m) }

        thinking_config = if thinking
          RubyLLM::Thinking::Config.new(**thinking.transform_keys(&:to_sym))
        end

        provider_instance.send(
          :render_payload,
          ruby_llm_messages,
          tools: {},
          temperature: temperature,
          model: model_info,
          stream: false,
          schema: schema,
          thinking: thinking_config
        ).merge(params)
      end

      def serialize_message(message)
        {
          "role" => message[:role].to_s,
          "content" => message[:content]
        }
      end

      def deep_stringify_keys(obj)
        case obj
        when Hash
          obj.transform_keys(&:to_s).transform_values { |v| deep_stringify_keys(v) }
        when Array
          obj.map { |v| deep_stringify_keys(v) }
        else
          obj
        end
      end
    end
  end
end
