# frozen_string_literal: true

require "patient_http"
require "prompt_builder"
require "uri"
require "json"
require "securerandom"

module PatientLLM
  VERSION = File.read(File.join(__dir__, "../VERSION")).strip

  autoload :Agent, File.expand_path("patient_llm/agent", __dir__)
  autoload :AwsRequestSigner, File.expand_path("patient_llm/aws_request_signer", __dir__)
  autoload :Callback, File.expand_path("patient_llm/callback", __dir__)
  autoload :Configuration, File.expand_path("patient_llm/configuration", __dir__)
  autoload :HaltError, File.expand_path("patient_llm/halt_error", __dir__)
  autoload :MaxToolIterationsError, File.expand_path("patient_llm/max_tool_iterations_error", __dir__)
  autoload :Presets, File.expand_path("patient_llm/presets", __dir__)
  autoload :RequestPreview, File.expand_path("patient_llm/request_preview", __dir__)
  autoload :Schema, File.expand_path("patient_llm/schema", __dir__)
  autoload :StructuredOutputError, File.expand_path("patient_llm/structured_output_error", __dir__)

  # Default API paths per serializer format. The Bedrock Converse and Gemini
  # paths embed a `{model}` placeholder that is replaced with the session's
  # model (percent-encoded as a single path segment) at dispatch time.
  SERIALIZER_PATHS = {
    chat_completion: "v1/chat/completions",
    open_responses: "v1/responses",
    messages: "v1/messages",
    converse: "model/{model}/converse",
    gemini: "v1beta/models/{model}:generateContent"
  }.freeze

  # Required version header for the Anthropic Messages API.
  ANTHROPIC_VERSION = "2023-06-01"

  # Valid serializer format names.
  VALID_SERIALIZERS = SERIALIZER_PATHS.keys.freeze

  # Key used in callback args to reference a session stored in a payload store.
  SESSION_REF_KEY = "$session_ref"

  class << self
    # Configure providers for LLM requests.
    #
    # @yield [Configuration]
    # @return [void]
    def configure
      @configuration ||= Configuration.new
      yield @configuration
    end

    # The current configuration.
    #
    # @return [Configuration, nil]
    attr_reader :configuration

    # Reset configuration. Primarily useful in tests.
    #
    # @return [void]
    def reset!
      @configuration = nil
    end

    # Look up a registered provider by name.
    #
    # @param name [Symbol, String] Provider name
    # @return [Hash, nil] Provider config
    def provider(name)
      @configuration&.lookup(name)
    end

    # Verify that the configuration is fully wired: a PatientHttp request handler
    # is registered, every secret referenced by a provider is registered, and
    # every preprocessor referenced by a provider is registered (when a default
    # PatientHttp configuration is available to check against).
    #
    # Call this at the end of your application initializer to surface wiring
    # mistakes at boot time instead of at dispatch time inside a job.
    #
    # @raise [RuntimeError] if any configuration problem is found
    # @return [true]
    def verify_configuration!
      errors = []

      unless PatientHttp.handler_registered?
        errors << "No PatientHttp request handler is registered. Add a job-system integration (patient_http-sidekiq or patient_http-solid_queue) or call PatientHttp.inline! for synchronous execution."
      end

      @configuration&.provider_names&.each do |name|
        provider_config = @configuration.lookup(name)

        provider_config[:headers].each do |header_name, value|
          next unless value.is_a?(PatientHttp::SecretReference)

          unless PatientHttp.secret_registered?(value.name)
            errors << "Provider #{name.inspect} header #{header_name.inspect} references secret #{value.name.inspect} but it is not registered with PatientHttp."
          end
        end

        patient_http_config = PatientHttp.default_configuration
        if patient_http_config
          Array(provider_config[:preprocessors]).each do |preprocessor_name|
            unless patient_http_config.preprocessor(preprocessor_name)
              errors << "Provider #{name.inspect} references preprocessor #{preprocessor_name.inspect} but it is not registered on the PatientHttp configuration."
            end
          end
        end
      end

      raise errors.join("\n") unless errors.empty?

      true
    end

    # Execute requests inline (synchronously, in-process) for the duration of
    # the block instead of dispatching through the registered PatientHttp
    # handler. Useful in consoles and tests; the automatic tool loop also runs
    # inline since it re-enters on the same thread.
    #
    # @yield the block during which requests execute inline
    # @return [Object] the block's return value
    def inline
      previous = Thread.current.thread_variable_get(:patient_llm_inline)
      Thread.current.thread_variable_set(:patient_llm_inline, true)
      begin
        yield
      ensure
        Thread.current.thread_variable_set(:patient_llm_inline, previous)
      end
    end

    # Check if requests are currently executing inline via {.inline}.
    #
    # @return [Boolean]
    def inline?
      !!Thread.current.thread_variable_get(:patient_llm_inline)
    end

    # Send an LLM request asynchronously using the given session and provider.
    #
    # @param session [PromptBuilder::Session] The prompt session containing conversation state
    # @param provider [Symbol, String] Registered provider name
    # @param callback [Class, String] Callback class for handling completion/error
    # @param callback_args [Hash] Custom arguments passed through to the callback
    # @param url [String, nil] Override the provider's base URL for this request
    # @param serializer [Symbol, nil] Override the provider's serializer for this request
    # @param path [String, nil] Override the endpoint path for this request
    # @param headers [Hash, nil] Additional headers merged on top of provider headers
    # @param params [Hash, nil] Additional params merged into the request payload
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] Names of request
    #   preprocessors to apply to this request. Replaces the provider's configured
    #   preprocessors; pass an empty array to clear them for this request.
    # @param timeout [Numeric, nil] Request timeout in seconds for this request. Overrides
    #   the provider's timeout; defaults to the PatientHttp processor configuration.
    # @param max_tool_iterations [Integer, nil] Maximum automatic tool-execution rounds
    #   for this request. Overrides the provider's setting; defaults to
    #   {Callback::MAX_TOOL_ITERATIONS}.
    # @return [Object] Handler-specific identifier for the enqueued request
    def ask(session, provider:, callback:, callback_args: {}, url: nil, serializer: nil, path: nil, headers: nil, params: nil, preprocessors: nil, timeout: nil, max_tool_iterations: nil)
      request_options = build_request_options(
        url: url,
        serializer: serializer,
        path: path,
        headers: headers,
        params: params,
        preprocessors: preprocessors,
        timeout: timeout,
        max_tool_iterations: max_tool_iterations
      )

      dispatch(session, provider: provider, callback: callback, callback_args: callback_args, request_options: request_options)
    end

    # Build the request that {.ask} would send without sending it. The same
    # resolution logic as {.ask} is applied: per-request overrides are merged
    # over the provider configuration, the session is serialized with the
    # resolved serializer, and provider params are merged into the payload.
    #
    # Nothing is enqueued or executed and no callback is required. Request
    # preprocessors (e.g. AWS SigV4 signing) run at send time in the request
    # processor, so their changes are not reflected in the preview. Header
    # values that reference registered secrets are replaced with placeholders
    # and never resolved.
    #
    # @param session [PromptBuilder::Session] The prompt session containing conversation state
    # @param provider [Symbol, String] Registered provider name
    # @param url [String, nil] Override the provider's base URL for this request
    # @param serializer [Symbol, nil] Override the provider's serializer for this request
    # @param path [String, nil] Override the endpoint path for this request
    # @param headers [Hash, nil] Additional headers merged on top of provider headers
    # @param params [Hash, nil] Additional params merged into the request payload
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] Accepted for
    #   parity with {.ask}; preprocessors are not applied to the preview.
    # @param timeout [Numeric, nil] Accepted for parity with {.ask}; does not affect the preview.
    # @param max_tool_iterations [Integer, nil] Accepted for parity with {.ask}; does not
    #   affect the preview.
    # @return [RequestPreview] The url, headers, and JSON payload the request would send
    def preview_request(session, provider:, url: nil, serializer: nil, path: nil, headers: nil, params: nil, preprocessors: nil, timeout: nil, max_tool_iterations: nil)
      request_options = build_request_options(
        url: url,
        serializer: serializer,
        path: path,
        headers: headers,
        params: params,
        preprocessors: preprocessors,
        timeout: timeout,
        max_tool_iterations: max_tool_iterations
      )

      resolved = resolve_request(session, self.provider(provider) || {}, request_options)

      RequestPreview.new(
        url: resolved.url,
        headers: redact_secret_headers(resolved.headers),
        payload: resolved.payload
      )
    end

    # Internal dispatch used by {.ask} and by {Callback} to re-issue requests
    # during the automatic tool loop. Not part of the public API.
    #
    # @api private
    def dispatch(session, provider:, callback:, callback_args:, request_options:, tool_iteration: 0, original_request_id: nil)
      provider_config = self.provider(provider) || {}
      provider_name = provider.to_s

      if tool_iteration.zero?
        PatientLLM::Callback.validate_callback_class!(PatientHttp::ClassHelper.resolve_class_name(callback.to_s))
      end

      resolved = resolve_request(session, provider_config, request_options)

      dispatch_callback_args = {
        session: session_payload(session),
        provider: provider_name,
        serializer: resolved.serializer.to_s,
        callback: callback.to_s,
        custom: PromptBuilder.jsonify(callback_args || {}),
        request_options: request_options,
        max_tool_iterations: resolved.max_tool_iterations,
        tool_iteration: tool_iteration,
        original_request_id: original_request_id
      }

      if inline?
        request = PatientHttp::Request.new(
          :post,
          resolved.url,
          json: resolved.payload,
          headers: resolved.headers,
          preprocessors: resolved.preprocessors,
          timeout: resolved.timeout
        )
        PatientHttp.execute_inline(
          request: request,
          callback: PatientLLM::Callback,
          callback_args: dispatch_callback_args,
          raise_error_responses: true
        )
      else
        PatientHttp.post(
          resolved.url,
          json: resolved.payload,
          headers: resolved.headers,
          preprocessors: resolved.preprocessors,
          timeout: resolved.timeout,
          raise_error_responses: true,
          callback: PatientLLM::Callback,
          callback_args: dispatch_callback_args
        )
      end
    end

    private

    # Fully resolved request produced by merging per-request options over the
    # provider configuration.
    ResolvedRequest = Data.define(:url, :serializer, :headers, :payload, :preprocessors, :timeout, :max_tool_iterations)
    private_constant :ResolvedRequest

    # Normalize per-request overrides into a request options hash. The request
    # options travel through the job queue in the callback args, which only
    # permit JSON-native values; convert Symbols (e.g. serializer names,
    # preprocessor names, header/param values) to Strings up front.
    def build_request_options(url:, serializer:, path:, headers:, params:, preprocessors:, timeout:, max_tool_iterations:)
      request_options = {}
      request_options["url"] = url if url
      request_options["serializer"] = serializer.to_s if serializer
      request_options["path"] = path if path
      request_options["headers"] = headers if headers && !headers.empty?
      request_options["params"] = params if params && !params.empty?
      request_options["preprocessors"] = preprocessors if preprocessors
      request_options["timeout"] = timeout if timeout
      request_options["max_tool_iterations"] = max_tool_iterations if max_tool_iterations

      PromptBuilder.jsonify(request_options)
    end

    # Resolve the request URL, headers, payload, and execution settings from
    # the request options merged over the provider configuration. This is the
    # single source of truth for what a request looks like; both {.dispatch}
    # and {.preview_request} build requests through it.
    def resolve_request(session, provider_config, request_options)
      resolved_url = request_options["url"] || provider_config[:url]
      raise ArgumentError, "No API base URL configured. Set url: or register a provider with a url." unless resolved_url

      resolved_serializer = (request_options["serializer"] || provider_config[:serializer] || :chat_completion).to_sym
      validate_serializer!(resolved_serializer)

      resolved_path = request_options["path"] || provider_config[:path] || SERIALIZER_PATHS[resolved_serializer]
      if resolved_path.include?("{model}")
        raise ArgumentError, "The endpoint path #{resolved_path.inspect} includes a {model} placeholder but session.model is not set" if session.model.nil?

        # Encode the model as a single path segment; Bedrock model ids can be
        # ARNs containing ":" and "/" that would otherwise splice extra path
        # segments into the URL and break SigV4 signing.
        resolved_path = resolved_path.gsub("{model}", URI.encode_uri_component(session.model.to_s))
      end

      resolved_headers = (provider_config[:headers] || {}).merge(request_options["headers"] || {})
      if resolved_serializer == :messages && !resolved_headers.key?("anthropic-version")
        resolved_headers = {"anthropic-version" => ANTHROPIC_VERSION}.merge(resolved_headers)
      end

      resolved_params = (provider_config[:params] || {}).merge(request_options["params"] || {})

      payload = session.request_payload(resolved_serializer)
      payload = deep_merge(payload, deep_stringify_keys(resolved_params)) unless resolved_params.empty?

      ResolvedRequest.new(
        url: join_url(resolved_url, resolved_path),
        serializer: resolved_serializer,
        headers: resolved_headers,
        payload: payload,
        preprocessors: request_options["preprocessors"] || provider_config[:preprocessors],
        timeout: request_options["timeout"] || provider_config[:timeout],
        max_tool_iterations: (request_options["max_tool_iterations"] || provider_config[:max_tool_iterations] || Callback::MAX_TOOL_ITERATIONS).to_i
      )
    end

    # Replace secret reference header values with placeholders so a preview
    # never resolves or exposes secret values.
    def redact_secret_headers(headers)
      headers.transform_values do |value|
        value.is_a?(PatientHttp::SecretReference) ? "<secret:#{value.name}>" : value
      end
    end

    # Serialize the session for the callback args, offloading it to a payload
    # store when session offloading is configured and the serialized session
    # exceeds the threshold. Offloaded payloads are not deleted after use so
    # job retries keep working; use a store with managed expiration (Redis TTL,
    # S3 lifecycle rules) to clean them up.
    def session_payload(session)
      session_hash = session.to_h
      offload = @configuration&.session_offload_options
      return session_hash unless offload
      return session_hash if JSON.generate(session_hash).bytesize <= offload[:threshold]

      store = PatientHttp.default_configuration&.payload_store(offload[:payload_store])
      unless store
        raise ArgumentError, "Session offload is configured with payload store #{offload[:payload_store].inspect} but it is not registered on the PatientHttp configuration"
      end

      key = "patient_llm/session/#{SecureRandom.uuid}"
      store.store(key, session_hash)
      {SESSION_REF_KEY => {"payload_store" => offload[:payload_store], "key" => key}}
    end

    def validate_serializer!(serializer)
      unless VALID_SERIALIZERS.include?(serializer)
        raise ArgumentError, "Unknown serializer: #{serializer.inspect}. Valid options: #{VALID_SERIALIZERS.map(&:inspect).join(", ")}"
      end
    end

    def join_url(base, path)
      base_uri = URI.parse(base)
      base_uri.path = "#{base_uri.path}/" unless base_uri.path&.end_with?("/")
      URI.join(base_uri, path).to_s
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

    def deep_stringify_keys(hash)
      return {} if hash.nil?
      hash.each_with_object({}) do |(k, v), acc|
        acc[k.to_s] = v.is_a?(Hash) ? deep_stringify_keys(v) : v
      end
    end
  end
end
