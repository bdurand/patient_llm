# frozen_string_literal: true

module PatientLLM
  # Base class for declarative LLM agents. An agent bundles everything about
  # one LLM integration in a single class: the provider, model, generation
  # settings, tools (schema and handler together), structured output schema,
  # and completion handling. The agent class itself is the callback identity,
  # so its name is what travels through the job queue — everything else stays
  # in code and is re-resolved in the worker process.
  #
  # @example
  #   class TripPlannerAgent < PatientLLM::Agent
  #     provider :openai
  #     model "gpt-5"
  #     instructions "You are a travel assistant. Be concise."
  #     temperature 0.3
  #     max_tool_iterations 5
  #
  #     tool :weather, "Get weather forecast for a city" do
  #       param :city, :string, "City name", required: true
  #       param :country, :string
  #     end
  #
  #     output do
  #       field :summary, :string, required: true
  #       field :packing_list, array: :string
  #     end
  #
  #     def weather(city:, country: nil)
  #       WeatherService.forecast(city: city, country: country)
  #     end
  #
  #     def completed(response)
  #       Trip.find(response.context[:trip_id]).update!(plan: response.object, agent_state: response.state)
  #     end
  #
  #     def failed(failure)
  #       Rails.logger.error("#{failure.error_type}: #{failure.message}")
  #     end
  #   end
  #
  #   TripPlannerAgent.ask("Plan a weekend in NYC", context: {trip_id: trip.id})
  #   TripPlannerAgent.continue(trip.agent_state, "Make it kid-friendly", context: {trip_id: trip.id})
  #   response = TripPlannerAgent.ask!("Plan a weekend in NYC")  # inline, for consoles and tests
  class Agent
    autoload :Response, File.expand_path("agent/response", __dir__)
    autoload :Failure, File.expand_path("agent/failure", __dir__)

    # Methods that implement the callback plumbing contract. Subclasses must
    # override the completed/failed/tool_round hooks instead.
    PLUMBING_METHODS = %i[on_complete on_tool_use on_error prepare handles_tool? invoke_tool].freeze

    # Declarations copied down to subclasses by the inherited hook.
    INHERITED_SETTINGS = %i[provider model instructions temperature reasoning max_output_tokens max_tool_iterations tools output_schema].freeze

    class << self
      # DSL: get or set the provider name for this agent.
      #
      # @param name [Symbol, String, nil] the registered provider name
      # @return [Symbol, nil]
      def provider(name = nil)
        @provider = name.to_sym unless name.nil?
        @provider
      end

      # DSL: get or set the model.
      #
      # @param value [String, nil]
      # @return [String, nil]
      def model(value = nil)
        @model = value unless value.nil?
        @model
      end

      # DSL: get or set the system instructions.
      #
      # @param value [String, nil]
      # @return [String, nil]
      def instructions(value = nil)
        @instructions = value unless value.nil?
        @instructions
      end

      # DSL: get or set the sampling temperature.
      #
      # @param value [Numeric, nil]
      # @return [Numeric, nil]
      def temperature(value = nil)
        @temperature = value unless value.nil?
        @temperature
      end

      # DSL: get or set the reasoning configuration. Accepts a portable effort
      # level (:minimal, :low, :medium, :high, :xhigh, :max) or explicit options
      # (effort: or budget_tokens:) which are applied with `session.think`.
      #
      # @param value [Symbol, String, nil] a portable effort level
      # @param effort [Symbol, String, nil] explicit effort level
      # @param budget_tokens [Integer, nil] explicit thinking token budget
      # @return [Hash, nil] the reasoning options
      def reasoning(value = nil, effort: nil, budget_tokens: nil)
        if value || effort || budget_tokens
          raise ArgumentError, "pass a level, effort:, or budget_tokens: — not more than one" if [value, effort, budget_tokens].compact.size > 1
          @reasoning = value ? {effort: value.to_s} : {effort: effort&.to_s, budget_tokens: budget_tokens}.compact
        end
        @reasoning
      end

      # DSL: get or set the maximum output tokens.
      #
      # @param value [Integer, nil]
      # @return [Integer, nil]
      def max_output_tokens(value = nil)
        @max_output_tokens = value unless value.nil?
        @max_output_tokens
      end

      # DSL: get or set the maximum automatic tool-execution rounds.
      #
      # @param value [Integer, nil]
      # @return [Integer, nil]
      def max_tool_iterations(value = nil)
        @max_tool_iterations = value unless value.nil?
        @max_tool_iterations
      end

      # DSL: declare a tool. The tool's handler is the instance method with the
      # same name; define it in the class body with keyword arguments matching
      # the declared parameters. The schema can be declared with a {Schema}
      # block or passed as a raw JSON Schema hash with parameters:.
      #
      # @param name [Symbol, String] the tool name (must be a valid method name)
      # @param description [String, nil] what the tool does
      # @param parameters [Hash, nil] a raw JSON Schema hash for the parameters
      # @param strict [Boolean, nil] whether strict schema adherence is requested
      # @yield an optional {Schema} block declaring the parameters
      # @return [void]
      def tool(name, description = nil, parameters: nil, strict: nil, &block)
        raise ArgumentError, "pass either parameters: or a schema block, not both" if parameters && block

        schema = parameters ? PromptBuilder.jsonify(parameters) : Schema.build(&block)
        tools[name.to_s] = {description: description, parameters: schema, strict: strict}
      end

      # The declared tools.
      #
      # @return [Hash<String, Hash>] tool name to declaration
      def tools
        @tools ||= {}
      end

      # DSL: declare a structured output schema. The model's response is parsed
      # into a Hash available as `response.object` in the completed hook. Use a
      # {Schema} block or pass a raw JSON Schema hash with schema:.
      #
      # @param schema [Hash, nil] a raw JSON Schema hash
      # @param name [String] the schema name sent to the provider
      # @param strict [Boolean, nil] whether strict schema adherence is requested
      # @yield an optional {Schema} block declaring the fields
      # @return [void]
      def output(schema: nil, name: "response", strict: nil, &block)
        raise ArgumentError, "pass either schema: or a schema block, not both" if schema && block
        raise ArgumentError, "output requires schema: or a schema block" if schema.nil? && block.nil?

        @output_schema = {
          name: name.to_s,
          schema: schema ? PromptBuilder.jsonify(schema) : Schema.build(&block),
          strict: strict
        }
      end

      # The declared output schema.
      #
      # @return [Hash, nil] the schema declaration (:name, :schema, :strict)
      attr_reader :output_schema

      # Send a message to the agent asynchronously. When the final response
      # arrives (after any automatic tool rounds), the agent's `completed` hook
      # is invoked in the worker; errors invoke `failed`.
      #
      # @param message [String, Array, Hash, nil] the user message to add
      # @param context [Hash] JSON-native data available as `context` on the
      #   response/failure objects in hooks and to tool methods
      # @param session [PromptBuilder::Session, nil] an existing session to use
      #   instead of building a new one
      # @param options [Hash] per-request overrides forwarded to {PatientLLM.ask}
      #   (url:, serializer:, path:, headers:, params:, preprocessors:, timeout:,
      #   max_tool_iterations:)
      # @return [Object] handler-specific identifier for the enqueued request
      def ask(message = nil, context: {}, session: nil, **options)
        session ||= build_session
        session.user(message) if message

        ask_options = {}
        ask_options[:max_tool_iterations] = max_tool_iterations if max_tool_iterations

        PatientLLM.ask(
          session,
          provider: provider_name!,
          callback: self,
          callback_args: {"context" => PromptBuilder.jsonify(context || {})},
          **ask_options.merge(options)
        )
      end

      # Continue a persisted conversation. The session is restored from the
      # state hash (as returned by `response.state`), the agent's *current*
      # configuration is re-applied to it (so instruction/tool/schema changes
      # deploy cleanly to older conversations), and the message is sent.
      #
      # @param state [Hash] a session state hash from `response.state`
      # @param message [String, Array, Hash, nil] the user message to add
      # @param context [Hash] JSON-native data available as `context` on the response/failure objects in hooks
      # @param options [Hash] per-request overrides forwarded to {PatientLLM.ask}
      # @return [Object] handler-specific identifier for the enqueued request
      def continue(state, message = nil, context: {}, **options)
        session = PromptBuilder::Session.from_h(state)
        apply_configuration(session)
        ask(message, context: context, session: session, **options)
      end

      # Send a message and execute the request inline (synchronously,
      # in-process), returning the final {Agent::Response}. The automatic tool
      # loop runs inline too. Intended for consoles, development, and tests.
      # The completed/failed hooks still run, so this exercises real code paths.
      #
      # @param message [String, Array, Hash, nil] the user message to add
      # @param context [Hash] JSON-native data available as `context` on the response/failure objects in hooks
      # @param session [PromptBuilder::Session, nil] an existing session to use
      # @param options [Hash] per-request overrides forwarded to {PatientLLM.ask}
      # @return [Agent::Response] the final response
      # @raise [PatientHttp::Error] when the request fails
      def ask!(message = nil, context: {}, session: nil, **options)
        capture = {}
        previous = Thread.current.thread_variable_get(:patient_llm_agent_capture)
        Thread.current.thread_variable_set(:patient_llm_agent_capture, capture)
        begin
          PatientLLM.inline do
            ask(message, context: context, session: session, **options)
          end
        ensure
          Thread.current.thread_variable_set(:patient_llm_agent_capture, previous)
        end

        raise capture[:error] if capture[:error]

        capture[:response] || raise("No response was captured; the request did not complete")
      end

      # Build a new session from the agent's declarations.
      #
      # @return [PromptBuilder::Session]
      def build_session
        raise ArgumentError, "#{self} must declare a model" unless model

        session = PromptBuilder::Session.new(model: model)
        apply_configuration(session)
        session
      end

      # Apply the agent's declarations to a session. Used for both new sessions
      # and sessions restored from persisted state.
      #
      # @param session [PromptBuilder::Session]
      # @return [PromptBuilder::Session]
      def apply_configuration(session)
        session.instructions = instructions if instructions
        session.temperature = temperature if temperature
        session.max_output_tokens = max_output_tokens if max_output_tokens
        session.think(**reasoning.transform_keys(&:to_sym)) if reasoning
        if output_schema
          session.json_output(output_schema[:schema], name: output_schema[:name], strict: output_schema[:strict])
        end
        tools.each do |name, declaration|
          session.register_tool(
            name,
            description: declaration[:description],
            parameters: declaration[:parameters],
            strict: declaration[:strict] || false
          )
        end
        session
      end

      # Check if a tool name is declared on this agent.
      #
      # @param name [Symbol, String] the tool name
      # @return [Boolean]
      def tool_declared?(name)
        tools.key?(name.to_s)
      end

      private

      def provider_name!
        provider || raise(ArgumentError, "#{self} must declare a provider")
      end

      def inherited(subclass)
        super
        INHERITED_SETTINGS.each do |setting|
          value = instance_variable_get(:"@#{setting}")
          next if value.nil?

          subclass.instance_variable_set(:"@#{setting}", deep_dup(value))
        end
      end

      def deep_dup(value)
        case value
        when Hash
          value.transform_values { |element| deep_dup(element) }
        when Array
          value.map { |element| deep_dup(element) }
        else
          value
        end
      end

      def method_added(name)
        super
        if PLUMBING_METHODS.include?(name) && self != PatientLLM::Agent
          raise ArgumentError, "#{self} must not redefine #{name}; override completed, failed, or tool_round instead"
        end
      end
    end

    # @return [PromptBuilder::Session, nil] the session for the current invocation
    attr_reader :session

    # @return [String, nil] the provider name for the current invocation
    attr_reader :provider

    # Plumbing: called by {Callback} before hooks and tool execution to make the
    # invocation state available to instance methods. Do not override.
    #
    # @api private
    def prepare(session: nil, provider: nil, callback_args: nil, http_response: nil, request_id: nil)
      @session = session
      @provider = provider
    end

    # Plumbing: adapter for the {Callback} contract. Do not override; implement
    # `completed(response)` instead.
    #
    # @api private
    def on_complete(session:, provider:, llm_response:, callback_args:, http_response:, request_id:)
      prepare(session: session, provider: provider, callback_args: callback_args, http_response: http_response, request_id: request_id)
      response = Response.new(
        llm_response,
        session: session,
        output_schema: self.class.output_schema,
        http_response: http_response,
        http_request_id: http_response&.request_id,
        context: extract_context(callback_args)
      )
      capture_result(:response, response)
      completed(response)
    end

    # Plumbing: adapter for the {Callback} contract. Do not override; implement
    # `tool_round(response)` instead.
    #
    # @api private
    def on_tool_use(session:, provider:, llm_response:, callback_args:, http_response:, request_id:)
      prepare(session: session, provider: provider, callback_args: callback_args, http_response: http_response, request_id: request_id)
      response = Response.new(
        llm_response,
        session: session,
        http_response: http_response,
        http_request_id: http_response&.request_id,
        context: extract_context(callback_args)
      )
      tool_round(response)
    end

    # Plumbing: adapter for the {Callback} contract. Do not override; implement
    # `failed(failure)` instead.
    #
    # @api private
    def on_error(session:, provider:, callback_args:, error:, http_response:, request_id:)
      prepare(session: session, provider: provider, callback_args: callback_args, http_response: http_response, request_id: request_id)
      http_request_id = http_response&.request_id
      http_request_id ||= error.request_id if error.respond_to?(:request_id)
      failure = Failure.new(
        error,
        session: session,
        http_response: http_response,
        http_request_id: http_request_id,
        context: extract_context(callback_args)
      )
      capture_result(:error, error)
      failed(failure)
    end

    # Plumbing: whether this agent handles the named tool with an instance
    # method. Used by {Callback} to route tool execution.
    #
    # @api private
    def handles_tool?(name)
      self.class.tool_declared?(name) && respond_to?(name.to_sym)
    end

    # Plumbing: invoke the tool's instance method with the LLM-provided
    # arguments as keywords. A tool method that declares a `context:` keyword
    # also receives the context passed to ask/continue, extracted from the
    # callback args supplied by {Callback}.
    #
    # @api private
    def invoke_tool(name, arguments, callback_args: nil)
      raise ArgumentError, "#{self.class} does not handle tool #{name.inspect}" unless handles_tool?(name)

      kwargs = (arguments || {}).transform_keys(&:to_sym)
      kwargs[:context] = extract_context(callback_args) if tool_accepts_context?(name)
      public_send(name.to_sym, **kwargs)
    end

    # Hook: invoked with the final {Agent::Response} after any automatic tool
    # rounds complete. Override in your agent.
    #
    # @param response [Agent::Response] the final response; exposes the text,
    #   structured output, session state, HTTP exchange, and context
    # @return [void]
    def completed(response)
    end

    # Hook: invoked when a request fails. Override in your agent. The default
    # implementation re-raises the error so unhandled failures are never
    # silently lost — under a job system this fails the callback job, making
    # the error visible to its retry and error reporting. During inline
    # execution the raise is skipped because ask! raises the captured error
    # itself (raising here as well would make the executor invoke the error
    # callback a second time with a wrapped error).
    #
    # @param failure [Agent::Failure] the failure; exposes the error along
    #   with the session, HTTP exchange, and context
    # @return [void]
    def failed(failure)
      raise failure.error unless Thread.current.thread_variable_get(:patient_llm_agent_capture)
    end

    # Hook: invoked once per automatic tool round, after the tools run and
    # before the next request is issued. Override in your agent to observe
    # intermediate progress.
    #
    # @param response [Agent::Response] the intermediate tool-call response
    # @return [void]
    def tool_round(response)
    end

    private

    # The context passed to ask/continue, as stored in the callback args.
    def extract_context(callback_args)
      PatientHttp::CallbackArgs.new((callback_args && callback_args[:context]) || {})
    end

    def tool_accepts_context?(name)
      method(name.to_sym).parameters.any? do |type, param_name|
        (type == :key || type == :keyreq) && param_name == :context
      end
    end

    def capture_result(key, value)
      capture = Thread.current.thread_variable_get(:patient_llm_agent_capture)
      capture[key] = value if capture.is_a?(Hash)
    end
  end
end
