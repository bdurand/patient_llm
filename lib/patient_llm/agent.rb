# frozen_string_literal: true

module PatientLLM
  # Base class for declarative LLM agents. An agent bundles everything about
  # one LLM integration in a single class: the provider, model, generation
  # settings, tools (schema and handler together), structured output schema,
  # and completion handling. The agent class itself is the callback identity,
  # so its name is what travels through the job queue — everything else stays
  # in code and is re-resolved in the worker process.
  #
  # Subclasses inherit every declaration from their parent agent class,
  # including tools and the output schema. Override a setting by redeclaring
  # it, or remove an inherited scalar setting by passing an explicit nil
  # (e.g. `temperature nil`).
  #
  # The completed/failed/tool_round hooks can be redirected to another class
  # for one request by passing it as the :callback option to {ask}; the agent
  # still supplies the configuration and the tools.
  #
  # @example
  #   class TripPlannerAgent < PatientLLM::Agent
  #     provider :openai
  #     model "gpt-5"
  #     system "You are a travel assistant. Be concise."
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

    # The user-facing hooks that a class passed as the :callback option to
    # {ask} may implement to take over from the agent's own hooks.
    HOOKS = %i[completed failed tool_round].freeze

    # Sentinel default distinguishing "called as a getter" from an explicit
    # nil, which removes the value (masking any inherited one).
    NOT_SPECIFIED = Object.new
    private_constant :NOT_SPECIFIED

    class << self
      # DSL: get or set the provider name for this agent. The value is
      # inherited from the parent agent class unless set; pass an explicit nil
      # to remove an inherited value.
      #
      # @param name [Symbol, String, nil] the registered provider name.
      #   Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically; the result is
      #   coerced to a Symbol at read time.
      # @return [Symbol, nil]
      def provider(name = NOT_SPECIFIED, &block)
        get_or_set_setting(:provider, name, block) { |value| value&.to_sym }
      end

      # DSL: get or set the model. The value is inherited from the parent
      # agent class unless set; pass an explicit nil to remove an inherited value.
      #
      # @param value [String, nil] the model name. Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically.
      # @return [String, nil]
      def model(value = NOT_SPECIFIED, &block)
        get_or_set_setting(:model, value, block)
      end

      # DSL: get or set the system message. The value is inherited from the
      # parent agent class unless set; pass an explicit nil to remove an
      # inherited value.
      #
      # @param value [String, nil] the system message. Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically.
      # @return [String, nil]
      def system(value = NOT_SPECIFIED, &block)
        get_or_set_setting(:system, value, block)
      end

      # DSL: get or set instructions for the last request. These are appended to
      # the system prompt on APIs that don't support instructions as a separate
      # field. The value is inherited from the parent agent class unless set;
      # pass an explicit nil to remove an inherited value.
      #
      # @param value [String, nil] the instructions. Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically.
      # @return [String, nil]
      def instructions(value = NOT_SPECIFIED, &block)
        get_or_set_setting(:instructions, value, block)
      end

      # DSL: get or set the sampling temperature. The value is inherited from
      # the parent agent class unless set; pass an explicit nil to remove an
      # inherited value.
      #
      # @param value [Numeric, nil] the temperature. Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically.
      # @return [Numeric, nil]
      def temperature(value = NOT_SPECIFIED, &block)
        get_or_set_setting(:temperature, value, block)
      end

      # DSL: get or set the reasoning configuration. Accepts a portable effort
      # level (:minimal, :low, :medium, :high, :xhigh, :max) or explicit options
      # (effort: or budget_tokens:) which are applied with `session.think`.
      # The value is inherited from the parent agent class unless set; pass an
      # explicit nil to remove an inherited value.
      #
      # @param value [Symbol, String, nil] a portable effort level.
      #   Passing and explicit nil removes the previously set value.
      # @param effort [Symbol, String, nil] explicit effort level
      # @param budget_tokens [Integer, nil] explicit thinking token budget
      # @return [Hash, nil] the reasoning options
      def reasoning(value = NOT_SPECIFIED, effort: nil, budget_tokens: nil)
        return inherited_setting(:reasoning) if value.equal?(NOT_SPECIFIED) && effort.nil? && budget_tokens.nil?

        passed = [(value.equal?(NOT_SPECIFIED) ? nil : value), effort, budget_tokens].compact
        raise ArgumentError, "pass a level, effort:, or budget_tokens: — not more than one" if passed.size > 1

        @reasoning = if passed.empty?
          nil
        elsif effort || budget_tokens
          {effort: effort&.to_s, budget_tokens: budget_tokens}.compact
        else
          {effort: value.to_s}
        end
      end

      # DSL: get or set the maximum output tokens. The value is inherited from
      # the parent agent class unless set; pass an explicit nil to remove an
      # inherited value.
      #
      # @param value [Integer, nil] the maximum output tokens. Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically.
      # @return [Integer, nil]
      def max_output_tokens(value = NOT_SPECIFIED, &block)
        get_or_set_setting(:max_output_tokens, value, block)
      end

      # DSL: get or set the maximum automatic tool-execution rounds. The value
      # is inherited from the parent agent class unless set; pass an explicit
      # nil to remove an inherited value.
      #
      # @param value [Integer, nil] the maximum automatic tool-execution rounds. Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically.
      # @return [Integer, nil]
      def max_tool_iterations(value = NOT_SPECIFIED, &block)
        get_or_set_setting(:max_tool_iterations, value, block)
      end

      # DSL: get or set provider-specific extra data set on sessions built by
      # this agent (e.g. the Bedrock Converse :guardrail_config). The
      # recognized keys depend on the serializer used for the request. The
      # value is inherited from the parent agent class unless set; redeclaring
      # replaces the whole hash. Pass an explicit nil to remove an inherited
      # value.
      #
      # @param value [Hash, nil] the extra data. Passing and explicit nil removes the previously set value.
      # @yield an optional block (or callable argument) called each time the
      #   value is read so it can be generated dynamically (e.g.
      #   +extra { LLMConfiguration.extra_hash }+); the result is validated
      #   and jsonified at read time.
      # @return [Hash, nil]
      def extra(value = NOT_SPECIFIED, &block)
        get_or_set_setting(:extra, value, block) do |resolved|
          raise ArgumentError, "extra must be a Hash" unless resolved.nil? || resolved.is_a?(Hash)
          resolved.nil? ? nil : PromptBuilder.jsonify(resolved)
        end
      end

      # DSL: declare a tool. The tool's handler is the instance method with the
      # same name; define it in the class body with keyword arguments matching
      # the declared parameters. The schema can be declared with a {Schema}
      # block or passed as a raw JSON Schema hash with parameters:.
      #
      # @param name [Symbol, String] the tool name (must be a valid method name).
      #   Passing and explicit nil removes the previously set value.
      # @param description [String, nil] what the tool does
      # @param parameters [Hash, nil] a raw JSON Schema hash for the parameters
      # @param strict [Boolean, nil] whether strict schema adherence is requested
      # @yield an optional {Schema} block declaring the parameters
      # @return [void]
      def tool(name, description = nil, parameters: nil, strict: nil, &block)
        raise ArgumentError, "pass either parameters: or a schema block, not both" if parameters && block

        schema = parameters ? PromptBuilder.jsonify(parameters) : Schema.build(&block)
        own_tools[name.to_s] = {description: description, parameters: schema, strict: strict}
      end

      # The declared tools, including tools inherited from parent agent
      # classes. A tool redeclared in a subclass replaces the inherited
      # declaration. The returned hash is a copy; declare tools with the
      # {tool} DSL method rather than mutating it.
      #
      # @return [Hash<String, Hash>] tool name to declaration
      def tools
        merged = (self == PatientLLM::Agent) ? {} : superclass.tools
        merged.merge!(deep_dup(own_tools))
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

      # The declared output schema, inherited from the parent agent class
      # unless declared with {output}.
      #
      # @return [Hash, nil] the schema declaration (:name, :schema, :strict)
      def output_schema
        inherited_setting(:output_schema)
      end

      # Send a message to the agent asynchronously. When the final response
      # arrives (after any automatic tool rounds), the agent's `completed` hook
      # is invoked in the worker; errors invoke `failed`.
      #
      # @param message [String, Array, Hash, nil] the user message to add
      # @param context [Hash] JSON-native data available as `context` on the
      #   response/failure objects in hooks and to tool methods
      # @param session [PromptBuilder::Session, nil] an existing session to use
      #   instead of building a new one
      # @param callback [Class, String, nil] a named class to receive the
      #   {HOOKS} instead of this agent. A fresh instance is created in the
      #   worker for each invocation; hooks the class does not implement fall
      #   back to the agent's own. Tools and configuration still come from the
      #   agent. Defaults to sending the hooks to the agent itself.
      # @param options [Hash] per-request overrides forwarded to {PatientLLM.ask}
      #   (url:, serializer:, path:, headers:, params:, preprocessors:, timeout:,
      #   max_tool_iterations:)
      # @return [Object] handler-specific identifier for the enqueued request
      def ask(message = nil, context: {}, session: nil, callback: nil, **options)
        session_options = options.slice(*PromptBuilder::Session::INITIALIZE_OPTIONS)
        raise ArgumentError.new("session options cannot be passed when a session is provided") if session && session_options.any?

        session ||= build_session(**session_options)
        session.user(message) if message

        ask_options = options.except(*PromptBuilder::Session::INITIALIZE_OPTIONS)
        iterations = max_tool_iterations
        ask_options[:max_tool_iterations] ||= iterations if iterations

        agent_callback_args = {"context" => PromptBuilder.jsonify(context || {})}
        callback_name = callback_class_name(callback)
        agent_callback_args["callback"] = callback_name if callback_name

        PatientLLM.ask(
          session,
          provider: provider_name!,
          callback: self,
          callback_args: agent_callback_args,
          **ask_options
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
      # @param options [Hash] per-request overrides forwarded to {ask} (including
      #   callback:) and {PatientLLM.ask}
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
      # @param options [Hash] per-request overrides forwarded to {ask} (including
      #   callback:) and {PatientLLM.ask}
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

      # Build a new session from the agent's declarations. Options passed by
      # the caller take precedence over the agent's declarations for the same
      # fields (pass an explicit nil to unset a declared value for one request).
      #
      # @return [PromptBuilder::Session]
      def build_session(**options)
        session = PromptBuilder::Session.new(**options)
        apply_configuration(session, except: options.keys)
        session.model ||= model
        session
      end

      # Apply the agent's declarations to a session. Used for both new sessions
      # and sessions restored from persisted state. Fields listed in +except+
      # are left untouched (used by {build_session} so per-request options win
      # over the agent's declarations).
      #
      # @param session [PromptBuilder::Session]
      # @param except [Array<Symbol>] session fields to skip
      # @return [PromptBuilder::Session]
      def apply_configuration(session, except: [])
        system_message = system
        instructions_value = instructions
        temperature_value = temperature
        max_output_tokens_value = max_output_tokens
        extra_value = extra
        apply_system_message(session, system_message) if system_message && !except.include?(:system)
        session.instructions = instructions_value if instructions_value && !except.include?(:instructions)
        session.temperature = temperature_value if temperature_value && !except.include?(:temperature)
        session.max_output_tokens = max_output_tokens_value if max_output_tokens_value && !except.include?(:max_output_tokens)
        session.extra = extra_value if extra_value && !except.include?(:extra)
        session.think(**reasoning.transform_keys(&:to_sym)) if reasoning && !except.include?(:reasoning)
        if output_schema && !except.include?(:text)
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

      # Resolve the :callback option to the class name that travels through the
      # job queue. The class is resolved here so an unusable callback fails
      # where ask was called rather than later in a worker process.
      def callback_class_name(callback)
        return nil if callback.nil?

        name = callback.is_a?(Module) ? callback.name : callback.to_s
        raise ArgumentError, "callback must be a named class or a class name" if name.nil? || name.empty?

        callback_class = PatientHttp::ClassHelper.resolve_class_name(name)
        raise ArgumentError, "callback #{name} is not a class" unless callback_class.is_a?(Class)
        unless HOOKS.any? { |hook| callback_class.method_defined?(hook) }
          raise ArgumentError, "#{callback_class} must define at least one of #{HOOKS.join(", ")} to be used as a callback"
        end

        name
      end

      # Set the agent's system message on the session, replacing an existing
      # system message in place (a session restored from persisted state
      # already carries the one applied on the previous turn). Replacing at
      # the same index keeps the response boundary of server-state sessions
      # pointing at the right items.
      def apply_system_message(session, message)
        index = session.items.index { |item| item.is_a?(PromptBuilder::Items::Message) && item.system? }
        if index
          session.items[index] = PromptBuilder::Items::Message.new(role: "system", content: message)
        else
          session.system(message)
        end
      end

      # Shared implementation of the scalar get-or-set DSL methods. With no
      # argument and no block, reads the setting; when the stored value
      # responds to #call it is called and the result used, so values can be
      # generated dynamically at request time. With an argument or a block,
      # stores it; a block or callable argument is stored as-is. The optional
      # coerce block applies the method's coercion/validation — at set time
      # for plain values, at read time for a callable's result.
      def get_or_set_setting(name, value, block, &coerce)
        if value.equal?(NOT_SPECIFIED) && block.nil?
          stored = inherited_setting(name)
          return stored unless stored.respond_to?(:call)

          resolved = stored.call
          coerce ? coerce.call(resolved) : resolved
        else
          raise ArgumentError, "pass either an argument or a block, not both" if !value.equal?(NOT_SPECIFIED) && block

          stored = block || value
          stored = coerce.call(stored) if coerce && !stored.respond_to?(:call)
          instance_variable_set(:"@#{name}", stored)
        end
      end

      # Look up a setting on this class, falling back to the parent agent
      # class when it was never set here. An explicitly removed setting (set
      # to nil) defines the instance variable, masking the inherited value.
      def inherited_setting(name)
        ivar = :"@#{name}"
        if instance_variable_defined?(ivar)
          instance_variable_get(ivar)
        elsif self != PatientLLM::Agent
          superclass.public_send(name)
        end
      end

      def own_tools
        @tools ||= {}
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
      @callback_delegate = build_callback_delegate(callback_args)
      if @callback_delegate.is_a?(PatientLLM::Agent)
        @callback_delegate.prepare(
          session: session,
          provider: provider,
          callback_args: callback_args,
          http_response: http_response,
          request_id: request_id
        )
      end
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
      dispatch_hook(:completed, response)
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
      dispatch_hook(:tool_round, response)
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
      dispatch_hook(:failed, failure)
    end

    # Plumbing: whether this agent handles the named tool with an instance
    # method. Used by {Callback} to route tool execution. Only methods defined
    # by the agent class hierarchy (or modules mixed into it) count as
    # handlers — a declared tool name that collides with an inherited Object
    # method must not route LLM-controlled invocations to it.
    #
    # @api private
    def handles_tool?(name)
      return false unless self.class.tool_declared?(name)

      method_name = name.to_sym
      return false unless respond_to?(method_name)

      ancestors = singleton_class.ancestors
      owner_index = ancestors.index(method(method_name).owner)
      agent_index = ancestors.index(PatientLLM::Agent)
      !owner_index.nil? && !agent_index.nil? && owner_index < agent_index
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
    # rounds complete. Override in your agent, or in a class passed as the
    # :callback option to {ask}.
    #
    # @param response [Agent::Response] the final response; exposes the text,
    #   structured output, session state, HTTP exchange, and context
    # @return [void]
    def completed(response)
    end

    # Hook: invoked when a request fails. Override in your agent, or in a class
    # passed as the :callback option to {ask}. The default
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
    # before the next request is issued. Override in your agent (or in a class
    # passed as the :callback option to {ask}) to observe intermediate progress.
    #
    # @param response [Agent::Response] the intermediate tool-call response
    # @return [void]
    def tool_round(response)
    end

    private

    # Send a user-facing hook to the class passed as the :callback option to
    # ask when it implements that hook, otherwise to this agent.
    def dispatch_hook(name, argument)
      target = @callback_delegate&.respond_to?(name) ? @callback_delegate : self
      target.public_send(name, argument)
    end

    # Instantiate the callback class named by the :callback option to ask, or
    # nil when the hooks belong to this agent.
    def build_callback_delegate(callback_args)
      class_name = callback_args&.fetch(:callback, nil)
      return nil if class_name.nil? || class_name.to_s.empty?

      callback_class = PatientHttp::ClassHelper.resolve_class_name(class_name.to_s)
      # An agent named as its own callback is just the default behavior.
      # Returning nil also keeps prepare from recursing into a second instance.
      return nil if callback_class == self.class

      callback_class.new
    end

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
