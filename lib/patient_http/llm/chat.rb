# frozen_string_literal: true

module PatientHttp
  module LLM
    # Chat is the main interface for making asynchronous LLM requests.
    # It provides a similar interface to RubyLLM::Chat but is designed
    # for async HTTP requests via Sidekiq.
    #
    # @example Basic usage
    #   chat = PatientHttp::LLM::Chat.new(callback: ChatCallback)
    #   chat.with_instructions("You are a helpful assistant")
    #   chat.add_message(role: :user, content: "Hello!")
    #   chat.ask
    #
    # @example With tools
    #   chat = PatientHttp::LLM::Chat.new(callback: ChatCallback)
    #   chat.with_tool(WeatherTool)
    #   chat.ask("What's the weather in SF?")
    #
    # @example With serialization for multi-turn conversations
    #   # In completion worker:
    #   def perform(chat, response)
    #     chat.add_message(response)
    #     # Save chat.dump for next turn
    #   end
    class Chat
      SERIALIZATION_VERSION = 1
      DEFAULT_MAX_TOOL_ITERATIONS = 25

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
            messages: data["messages"],
            tools: deserialize_tools(data["tools"]),
            max_tool_iterations: data["max_tool_iterations"]
          )
        end

        private

        # Resolve an array of tool class name strings into tool instances.
        #
        # @param tool_names [Array<String>, nil] Tool class names
        # @return [Array<RubyLLM::Tool>, nil]
        def deserialize_tools(tool_names)
          return nil if tool_names.nil? || tool_names.empty?

          tool_names.map do |name|
            klass = PatientHttp::ClassHelper.resolve_class_name(name)
            klass.new
          end
        end
      end

      attr_reader :messages, :model, :provider, :temperature, :thinking_effort, :thinking_budget,
        :schema, :params, :headers, :callback, :api_base, :tools, :max_tool_iterations

      # Initialize a new Chat instance.
      #
      # @param callback [Class, String] The callback instance to handle completion and error events
      # @param model [String, nil] Model identifier (e.g., "gpt-4", "claude-3-opus")
      # @param provider [String, Symbol, nil] Provider identifier (e.g., "openai", "anthropic")
      # @param api_base [String, nil] Override the provider's API base URL (for LM Studio, etc.)
      # @param tools [Array<Class, RubyLLM::Tool>, nil] Tool classes or instances to register
      # @param max_tool_iterations [Integer, nil] Maximum number of tool call loop iterations
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
        headers: nil,
        tools: nil,
        max_tool_iterations: nil
      )
        @callback = callback
        @model = model
        @provider = provider&.to_s
        @api_base = api_base
        @completion_path = completion_path
        @messages = []
        @temperature = temperature
        @thinking_effort = thinking_effort&.to_s
        @thinking_budget = thinking_budget
        @schema = nil
        @params = params || {}
        @headers = headers || {}
        @tools = {}
        @max_tool_iterations = max_tool_iterations || DEFAULT_MAX_TOOL_ITERATIONS

        with_instructions(instructions) if instructions
        add_messages(messages) if messages
        with_schema(schema) if schema
        with_tools(*tools) if tools
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
        return unless @thinking_effort || @thinking_budget

        {effort: @thinking_effort, budget: @thinking_budget}
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

      # Register a single tool for the chat.
      #
      # @param tool [Class, RubyLLM::Tool] A tool class or instance
      # @return [self]
      def with_tool(tool)
        tool_instance = tool.is_a?(Class) ? tool.new : tool
        @tools[tool_instance.name.to_sym] = tool_instance
        self
      end

      # Register multiple tools for the chat.
      #
      # @param tools [Array<Class, RubyLLM::Tool>] Tool classes or instances
      # @return [self]
      def with_tools(*tools)
        tools.flatten.each { |tool| with_tool(tool) }
        self
      end

      # Set the maximum number of tool call loop iterations.
      #
      # @param max [Integer] Maximum iterations (default: 25)
      # @return [self]
      def with_max_tool_iterations(max)
        @max_tool_iterations = max
        self
      end

      # Add multiple messages to the conversation.
      #
      # @param messages [Array<Hash, RubyLLM::Message, String>] Messages to add
      # @return [self]
      def add_messages(messages)
        messages.each do |m|
          add_message(m)
        end
        self
      end

      # Add a message to the conversation.
      # Supports plain text messages, hash messages, and RubyLLM::Message objects
      # including those with tool_calls and tool_call_id.
      #
      # @param message_or_attrs [Hash, RubyLLM::Message, String] Message hash or object
      # @return [self]
      def add_message(message_or_attrs)
        message = if message_or_attrs.is_a?(Hash)
          deserialize_message_hash(message_or_attrs)
        elsif message_or_attrs.respond_to?(:role) && message_or_attrs.respond_to?(:content)
          message_from_object(message_or_attrs)
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
      # @return [String] Request id that will be used when making the request
      def ask(message = nil, callback_args: {})
        add_message(role: :user, content: message) if message

        model_info, provider_instance = resolve_model_and_provider
        payload = build_payload(model_info, provider_instance)

        base_url = api_base || provider_instance.api_base
        request_url = URI.join(base_url, completion_path).to_s
        request_headers = provider_instance.headers.merge(headers)

        PatientHttp.post(
          request_url,
          json: payload,
          headers: request_headers,
          raise_error_responses: true,
          callback: PatientHttp::LLM::Callback,
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
        data = {
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

        data["tools"] = serialize_tools if tools.any?
        data["max_tool_iterations"] = max_tool_iterations if max_tool_iterations != DEFAULT_MAX_TOOL_ITERATIONS

        data
      end

      alias_method :dump, :as_json

      # Get the URL path for the chat completion endpoint. Defaults to the endpoint
      # defined by the provider if not explicitly set.
      #
      # @return [String, nil]
      def completion_path
        return @completion_path if @completion_path

        _model, provider_instance = resolve_model_and_provider
        provider_instance&.send(:completion_url)
      end

      private

      def deserialize_message_hash(message_hash)
        role = message_hash[:role] || message_hash["role"]
        content = message_hash[:content] || message_hash["content"]
        tool_calls = message_hash[:tool_calls] || message_hash["tool_calls"]
        tool_call_id = message_hash[:tool_call_id] || message_hash["tool_call_id"]

        # Assistant messages with tool_calls may have empty/nil content
        valid = role && (content || tool_calls) && role != ""
        unless valid
          raise ArgumentError.new("Message hash must have role and content; actual keys: #{message_hash.keys.join(", ")}")
        end

        msg = {role: role.to_sym, content: content || ""}
        msg[:tool_calls] = deserialize_tool_calls(tool_calls) if tool_calls
        msg[:tool_call_id] = tool_call_id if tool_call_id
        msg
      end

      # Convert a message-like object (e.g. RubyLLM::Message) to an internal hash.
      #
      # @param obj [Object] An object responding to #role and #content
      # @return [Hash]
      def message_from_object(obj)
        msg = {role: obj.role.to_sym, content: obj.content}

        if obj.respond_to?(:tool_calls) && obj.tool_calls && !obj.tool_calls.empty?
          msg[:tool_calls] = obj.tool_calls.transform_values do |tc|
            {id: tc.id, name: tc.name, arguments: tc.arguments}
          end
        end

        msg[:tool_call_id] = obj.tool_call_id if obj.respond_to?(:tool_call_id) && obj.tool_call_id

        msg
      end

      # Deserialize tool_calls from serialized hash form.
      #
      # @param tool_calls [Hash] Serialized tool calls
      # @return [Hash]
      def deserialize_tool_calls(tool_calls)
        tool_calls.to_h do |id, tc|
          tc = tc.transform_keys(&:to_s) if tc.is_a?(Hash)
          call_id = tc["id"] || id
          [call_id.to_s, {
            "id" => call_id.to_s,
            "name" => tc["name"],
            "arguments" => tc["arguments"] || {}
          }]
        end
      end

      # Return the resolved model and provider instance.
      #
      # @return [Array(RubyLLM::Model, RubyLLM::Provider)]
      def resolve_model_and_provider
        RubyLLM::Models.resolve(@model, provider: @provider, assume_exists: true)
      end

      def build_payload(model_info, provider_instance)
        ruby_llm_messages = messages.map { |m| build_ruby_llm_message(m) }

        thinking_config = (RubyLLM::Thinking::Config.new(**thinking.transform_keys(&:to_sym)) if thinking)

        provider_instance.send(
          :render_payload,
          ruby_llm_messages,
          tools: tools,
          temperature: temperature,
          model: model_info,
          stream: false,
          schema: schema,
          thinking: thinking_config
        ).then { |payload| RubyLLM::Utils.deep_merge(payload, params) }
      end

      # Build a RubyLLM::Message from an internal message hash, preserving
      # tool_calls and tool_call_id when present.
      #
      # @param message [Hash] Internal message hash
      # @return [RubyLLM::Message]
      def build_ruby_llm_message(message)
        attrs = {role: message[:role], content: message[:content]}

        if message[:tool_calls]
          attrs[:tool_calls] = message[:tool_calls].transform_values do |tc|
            tc = tc.transform_keys(&:to_s) if tc.is_a?(Hash)
            RubyLLM::ToolCall.new(
              id: tc["id"],
              name: tc["name"],
              arguments: symbolize_arguments(tc["arguments"] || {})
            )
          end
        end

        attrs[:tool_call_id] = message[:tool_call_id] if message[:tool_call_id]

        RubyLLM::Message.new(**attrs)
      end

      def symbolize_arguments(args)
        return {} unless args.is_a?(Hash)

        args.transform_keys(&:to_sym)
      end

      def serialize_message(message)
        msg = {
          "role" => message[:role].to_s,
          "content" => message[:content]
        }

        if message[:tool_calls]
          msg["tool_calls"] = message[:tool_calls].transform_values do |tc|
            tc = tc.transform_keys(&:to_s) if tc.is_a?(Hash)
            {
              "id" => tc["id"],
              "name" => tc["name"],
              "arguments" => deep_stringify_keys(tc["arguments"] || {})
            }
          end
        end

        msg["tool_call_id"] = message[:tool_call_id] if message[:tool_call_id]

        msg
      end

      def serialize_tools
        tools.values.map { |tool| tool.class.name }
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
