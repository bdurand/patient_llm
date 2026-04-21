# frozen_string_literal: true

module PatientHttp
  module LLM
    # Chat is the main interface for making asynchronous LLM requests.
    # It builds OpenAI Chat Completions API payloads and dispatches them
    # via PatientHttp for async execution.
    #
    # @example Basic usage
    #   chat = PatientHttp::LLM::Chat.new(callback: ChatCallback, model: "gpt-4", provider: :openai)
    #   chat.with_instructions("You are a helpful assistant")
    #   chat.add_message(role: :user, content: "Hello!")
    #   chat.ask
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
            thinking_effort: data["thinking_effort"],
            schema: data["schema"],
            params: data["params"],
            headers: data["headers"],
            tools: data["tools"],
            messages: data["messages"]
          )
        end
      end

      attr_reader :messages, :model, :provider, :temperature, :thinking_effort,
        :schema, :params, :headers, :callback, :api_base, :tools

      # Initialize a new Chat instance.
      #
      # @param callback [Class, String] The callback class whose instance handles completion and error events
      # @param model [String, nil] Model identifier (e.g., "gpt-4")
      # @param provider [String, Symbol, nil] Provider registry key
      # @param api_base [String, nil] Override the provider's API base URL
      # @param completion_path [String, nil] Override the completion endpoint path
      # @param instructions [String, nil] Optional system instructions to prepend
      # @param messages [Array<Hash>, nil] Prior messages (used by load)
      # @param temperature [Float, nil] Sampling temperature
      # @param thinking_effort [String, Symbol, nil] Reasoning effort ("low", "medium", "high")
      # @param schema [Hash, Object, nil] JSON schema for structured output
      # @param params [Hash, nil] Provider-specific parameters
      # @param headers [Hash, nil] Custom HTTP headers
      # @param tools [Array<Tool, String, Class>, nil] Tool instances or class names
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
        schema: nil,
        params: nil,
        headers: nil,
        tools: nil
      )
        @callback = callback
        @model = model
        @provider = provider&.to_s
        @api_base = api_base
        @completion_path = completion_path
        @messages = []
        @temperature = temperature
        @thinking_effort = thinking_effort&.to_s
        @schema = nil
        @params = params || {}
        @headers = headers || {}
        @tools = resolve_tools(tools)

        with_instructions(instructions) if instructions
        add_messages(messages) if messages
        with_schema(schema) if schema
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

      # Enable extended thinking / reasoning for supported models (e.g. OpenAI o1/o3).
      #
      # @param effort [String, Symbol, nil] Reasoning effort level ("low", "medium", "high")
      # @return [self]
      def with_thinking(effort:)
        @thinking_effort = effort&.to_s
        self
      end

      # Disable extended thinking mode.
      #
      # @return [self]
      def without_thinking
        @thinking_effort = nil
        self
      end

      # Get current thinking configuration.
      #
      # @return [Hash, nil]
      def thinking
        {effort: @thinking_effort} if @thinking_effort
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
      # Do not put secrets (e.g. Authorization tokens) here: chat state is
      # serialized into the job queue along with these headers. Configure
      # provider-level headers via `PatientHttp::LLM.configure` instead —
      # those are re-attached at request time and never persisted.
      #
      # @param headers [Hash] Headers to merge
      # @return [self]
      def with_headers(headers)
        @headers.merge!(headers)
        self
      end

      # Set tools for function calling.
      #
      # @param tools [Array<Tool>] Tool instances
      # @return [self]
      def with_tools(tools)
        @tools = resolve_tools(tools)
        self
      end

      # Add multiple messages to the conversation.
      #
      # @param messages [Array<Hash>] Messages to add
      # @return [self]
      def add_messages(messages)
        messages.each do |m|
          add_message(m)
        end
        self
      end

      # Add a message to the conversation.
      #
      # @param message_or_attrs [Hash, Message, String] Message hash, Message object, or string
      # @return [self]
      def add_message(message_or_attrs)
        message = if message_or_attrs.is_a?(Hash)
          deserialize_message_hash(message_or_attrs)
        elsif message_or_attrs.respond_to?(:role) && message_or_attrs.respond_to?(:content)
          hash = {role: message_or_attrs.role.to_sym, content: message_or_attrs.content}
          if message_or_attrs.respond_to?(:tool_calls) && !message_or_attrs.tool_calls.empty?
            hash[:tool_calls] = message_or_attrs.tool_calls
          end
          if message_or_attrs.respond_to?(:tool_call_id) && message_or_attrs.tool_call_id
            hash[:tool_call_id] = message_or_attrs.tool_call_id
          end
          hash
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
      # @return [Object] Handler-specific identifier for the enqueued request (usually a request id String)
      def ask(message = nil, callback_args: {}, tool_iteration: 0)
        add_message(role: :user, content: message) if message

        payload = build_payload
        base_url, request_headers = resolve_request_config

        request_url = join_url(base_url, completion_path)

        PatientHttp.post(
          request_url,
          json: payload,
          headers: request_headers,
          raise_error_responses: true,
          callback: PatientHttp::LLM::Callback,
          callback_args: {
            chat: as_json,
            chat_callback: @callback&.to_s,
            custom: CallbackArgs.deep_stringify_keys(callback_args),
            tool_iteration: tool_iteration
          }
        )
      end

      # Serialize the chat to a JSON-compatible hash.
      #
      # Tool instances are stored by class name so they can be rehydrated via
      # `Chat.load`. Tool classes must be loadable (e.g. via autoload) at
      # callback-execution time.
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
          "schema" => CallbackArgs.deep_stringify_keys(schema),
          "params" => CallbackArgs.deep_stringify_keys(params),
          "headers" => CallbackArgs.deep_stringify_keys(headers),
          "tools" => tools.map { |t| t.class.name }
        }
      end

      alias_method :dump, :as_json

      # Get the URL path for the chat completion endpoint.
      #
      # @return [String]
      def completion_path
        @completion_path || "/v1/chat/completions"
      end

      private

      def deserialize_message_hash(message_hash)
        role = message_hash[:role] || message_hash["role"]
        content = message_hash[:content] || message_hash["content"]
        tool_calls = message_hash[:tool_calls] || message_hash["tool_calls"]
        tool_call_id = message_hash[:tool_call_id] || message_hash["tool_call_id"]

        unless role && role != ""
          raise ArgumentError.new("Message hash must have a role; actual keys: #{message_hash.keys.join(", ")}")
        end

        has_content = !content.nil? && content != ""
        has_tool_calls = tool_calls && !tool_calls.empty?
        has_tool_call_id = tool_call_id && tool_call_id != ""

        unless has_content || has_tool_calls || has_tool_call_id
          raise ArgumentError.new("Message hash must have content, tool_calls, or tool_call_id; actual keys: #{message_hash.keys.join(", ")}")
        end

        msg = {role: role.to_sym, content: content}
        msg[:tool_calls] = normalize_tool_calls(tool_calls) if has_tool_calls
        msg[:tool_call_id] = tool_call_id if has_tool_call_id
        msg
      end

      def normalize_tool_calls(tool_calls)
        tool_calls.each_with_object({}) do |(id, tc), hash|
          hash[id.to_s] = if tc.is_a?(ToolCall)
            tc
          else
            ToolCall.load(id.to_s, tc)
          end
        end
      end

      def build_payload
        payload = PayloadBuilder.build(
          messages: messages,
          model: model,
          tools: tools.any? ? tools : nil,
          temperature: temperature,
          schema: schema,
          thinking: thinking
        )

        deep_merge(payload, params)
      end

      def resolve_request_config
        provider_config = PatientHttp::LLM.provider(provider)

        base_url = api_base || provider_config&.dig(:url)
        raise ArgumentError, "No API base URL configured. Set api_base on the chat or register a provider." unless base_url

        provider_headers = provider_config&.dig(:headers) || {}
        request_headers = provider_headers.merge(headers)

        [base_url, request_headers]
      end

      # Join an API base URL and a path by stripping the base's trailing slash
      # and the path's leading slash, then joining with a single "/". This
      # preserves any path prefix on the base (unlike URI.join with absolute
      # paths, which would discard it).
      def join_url(base, path)
        "#{base.sub(%r{/\z}, "")}/#{path.to_s.sub(%r{\A/}, "")}"
      end

      def serialize_message(message)
        msg = {
          "role" => message[:role].to_s,
          "content" => message[:content]
        }
        if message[:tool_calls] && !message[:tool_calls].empty?
          msg["tool_calls"] = serialize_tool_calls(message[:tool_calls])
        end
        if message[:tool_call_id]
          msg["tool_call_id"] = message[:tool_call_id]
        end
        msg
      end

      def serialize_tool_calls(tool_calls)
        tool_calls.each_with_object({}) do |(id, tc), hash|
          hash[id.to_s] = if tc.is_a?(ToolCall)
            tc.as_json
          else
            CallbackArgs.deep_stringify_keys(tc)
          end
        end
      end

      def resolve_tools(tools)
        return [] if tools.nil? || tools.empty?

        tools.map do |t|
          case t
          when Tool
            t
          when Class
            t.new
          when String
            klass = PatientHttp::ClassHelper.resolve_class_name(t)
            raise ArgumentError.new("Could not resolve tool class: #{t.inspect}") unless klass
            klass.new
          else
            raise ArgumentError.new("Tool must be a Tool instance, Class, or class name String; got #{t.class.name}")
          end
        end
      end

      def deep_merge(hash1, hash2)
        hash1.merge(hash2) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end
    end
  end
end
