# frozen_string_literal: true

module Sidekiq
  module AsyncLLM
    # Chat is the main interface for making asynchronous LLM requests.
    # It provides a similar interface to RubyLLM::Chat but is designed
    # for async HTTP requests via Sidekiq.
    #
    # @example Basic usage
    #   chat = Sidekiq::AsyncLLM::Chat.new(
    #     completion_worker: MyCompletionWorker,
    #     error_worker: MyErrorWorker,
    #     model: "gpt-4"
    #   )
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

      attr_reader :messages, :model, :provider, :temperature, :thinking,
        :schema, :params, :headers, :completion_worker, :error_worker, :api_base

      # Initialize a new Chat instance.
      #
      # @param completion_worker [Class] Sidekiq worker class for successful completions
      # @param error_worker [Class] Sidekiq worker class for errors
      # @param model [String, nil] Model identifier (e.g., "gpt-4", "claude-3-opus")
      # @param provider [String, Symbol, nil] Provider identifier (e.g., "openai", "anthropic")
      # @param api_base [String, nil] Override the provider's API base URL (for LM Studio, etc.)
      def initialize(completion_worker:, error_worker:, model: nil, provider: nil, api_base: nil)
        @completion_worker = completion_worker
        @error_worker = error_worker
        @model = model
        @provider = provider&.to_s
        @api_base = api_base
        @messages = []
        @temperature = nil
        @thinking = nil
        @schema = nil
        @params = {}
        @headers = {}
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
        @thinking = {effort: effort&.to_s, budget: budget}.compact
        @thinking = nil if @thinking.empty?
        self
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
      def with_params(**params)
        @params.merge!(params)
        self
      end

      # Add custom HTTP headers.
      #
      # @param headers [Hash] Headers to merge
      # @return [self]
      def with_headers(**headers)
        @headers.merge!(headers)
        self
      end

      # Add a message to the conversation.
      #
      # @param message_or_attrs [Hash, RubyLLM::Message] Message hash or object
      # @return [self]
      def add_message(message_or_attrs)
        message = if message_or_attrs.is_a?(Hash)
          message_or_attrs.transform_keys(&:to_sym)
        elsif message_or_attrs.respond_to?(:role) && message_or_attrs.respond_to?(:content)
          {role: message_or_attrs.role.to_sym, content: message_or_attrs.content}
        else
          raise ArgumentError, "Message must be a Hash or respond to #role and #content"
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

        connection = build_connection(provider_instance)
        connection.post(completion_path(provider_instance)) do |req|
          req.body = payload.to_json
          req.options.context = {
            sidekiq_async_http: {
              completion_worker: resolve_worker_class(completion_worker),
              error_worker: resolve_worker_class(error_worker),
              callback_args: {
                chat: as_json,
                provider: provider_instance.class.slug.to_s,
                model: model_info.id,
                custom: deep_stringify_keys(callback_args)
              }
            }
          }
        end
      end

      alias_method :say, :ask

      # Serialize the chat to a JSON-compatible hash.
      #
      # @return [Hash]
      def as_json
        {
          "v" => SERIALIZATION_VERSION,
          "completion_worker" => worker_to_string(completion_worker),
          "error_worker" => worker_to_string(error_worker),
          "model" => model,
          "provider" => provider,
          "api_base" => api_base,
          "messages" => messages.map { |m| serialize_message(m) },
          "temperature" => temperature,
          "thinking" => deep_stringify_keys(thinking),
          "schema" => deep_stringify_keys(schema),
          "params" => deep_stringify_keys(params),
          "headers" => deep_stringify_keys(headers)
        }
      end

      alias_method :dump, :as_json

      # Deserialize a chat from a JSON hash.
      #
      # @param data [Hash] Serialized chat data
      # @return [Chat]
      def self.load(data)
        data = data.transform_keys(&:to_s) if data.is_a?(Hash)

        chat = new(
          completion_worker: string_to_worker(data["completion_worker"]),
          error_worker: string_to_worker(data["error_worker"]),
          model: data["model"],
          provider: data["provider"],
          api_base: data["api_base"]
        )

        chat.instance_variable_set(:@messages, deserialize_messages(data["messages"] || []))
        chat.instance_variable_set(:@temperature, data["temperature"])
        chat.instance_variable_set(:@thinking, data["thinking"])
        chat.instance_variable_set(:@schema, data["schema"])
        chat.instance_variable_set(:@params, data["params"] || {})
        chat.instance_variable_set(:@headers, data["headers"] || {})

        chat
      end

      private

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

      def build_connection(provider_instance)
        base_url = api_base || provider_instance.api_base
        Faraday.new(url: base_url) do |f|
          f.request :json
          f.headers = provider_instance.headers.merge(headers)
          f.adapter :sidekiq_async_http
        end
      end

      def completion_path(provider_instance)
        # Most providers use similar paths
        case provider_instance.class.slug.to_s
        when "anthropic"
          "/v1/messages"
        when "gemini"
          "/v1beta/models/#{@model}:generateContent"
        when "bedrock"
          "/model/#{@model}/invoke"
        else
          # OpenAI and compatible APIs
          "/v1/chat/completions"
        end
      end

      def resolve_worker_class(worker)
        case worker
        when Class
          worker
        when String
          Object.const_get(worker)
        else
          worker
        end
      end

      def worker_to_string(worker)
        case worker
        when Class
          worker.name
        when String
          worker
        else
          worker.to_s
        end
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

      class << self
        private

        def string_to_worker(str)
          return str if str.is_a?(Class)
          Object.const_get(str)
        end

        def deserialize_messages(messages)
          messages.map do |m|
            {
              role: m["role"].to_sym,
              content: m["content"]
            }
          end
        end
      end
    end
  end
end
