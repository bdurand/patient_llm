# frozen_string_literal: true

module PatientLLM
  # Headers that must be setup to use the secrets manager. If any of these headers
  # are included in the provider configuration, an error will be raised unless their
  # values are set up as secrets using `PatientHttp.secret`.
  AUTHENTICATION_HEADERS = ["authorization", "x-api-key", "x-goog-api-key", "api-key"].freeze

  # Configuration for provider registry.
  #
  # Providers can be registered from a built-in preset, which supplies the
  # vendor's base URL, serializer, and authentication header details, so that
  # registering a provider and wiring up its API key is a single step:
  #
  # @example Using presets
  #   PatientLLM.configure do |config|
  #     config.provider :openai, preset: :openai, api_key: -> { ENV["OPENAI_API_KEY"] }
  #     config.provider :anthropic, preset: :anthropic, api_key: -> { ENV["ANTHROPIC_API_KEY"] }
  #   end
  #
  # @example Fully custom provider
  #   PatientLLM.configure do |config|
  #     config.provider :local, url: "http://localhost:1234", headers: {}
  #   end
  class Configuration
    # Prefix for secret names derived from provider names by the api_key option.
    SECRET_NAME_PREFIX = "patient_llm"

    attr_reader :session_offload_options

    # Name of the PatientHttp processor that executes LLM requests, used when a
    # request does not pass its own processor: option. The value can be a
    # Symbol, a String, or a callable resolved on every request. When nil, the
    # default processor is used.
    #
    # @return [Symbol, String, #call, nil]
    attr_accessor :processor

    def initialize
      @providers = {}
      @session_offload_options = nil
      @processor = nil
    end

    # Register a provider.
    #
    # When a +preset+ is given, its values are used as defaults; any explicit
    # keyword argument overrides the preset. When +api_key+ is given, the key is
    # registered as a PatientHttp secret named +patient_llm.<name>.api_key+ and
    # referenced from the provider's authentication header, so no separate
    # +register_secret+ call is needed. The key value itself is never serialized
    # into requests; only the secret name travels with them.
    #
    # Arguments passed as a callable object (responds to `:call`) are evaluated
    # at runtime on every request.
    #
    # @param name [Symbol, String] Provider name
    # @param preset [Symbol, nil] Built-in preset name (:openai, :anthropic, :gemini, :bedrock_runtime)
    # @param url [String, #call, nil] Base URL for the provider API
    # @param api_key [#call, String, PatientHttp::SecretReference, nil] The API key for the provider.
    #   A Proc or callable object is resolved at dispatch time (preferred). A String is captured into the secret
    #   registry and never serialized. A SecretReference uses your own registered secret as-is.
    #   This option can only be used in conjunction with a preset.
    # @param region [String, #call, nil] Region for presets with region-based URLs (e.g. :bedrock_runtime)
    # @param headers [Hash, #call, nil] Default headers for requests (merged over preset headers)
    # @param serializer [Symbol, #call, nil] API format (:chat_completion, :open_responses, :messages, :converse, :gemini)
    # @param path [String, #call, nil] Override the default endpoint path
    # @param params [Hash, #call] Additional parameters to merge into every request payload
    # @param preprocessors [String, Symbol, Array<String, Symbol>, #call, nil] Names of request
    #   preprocessors to apply to every request (e.g. for request signing). Names must be
    #   registered on the PatientHttp configuration with `register_preprocessor`.
    # @param timeout [Numeric, #call, nil] Request timeout in seconds for this provider's requests
    # @param max_tool_iterations [Integer, #call, nil] Maximum automatic tool-execution rounds
    #   for this provider's requests (default: PatientLLM::Callback::MAX_TOOL_ITERATIONS)
    # @return [void]
    def provider(name, preset: nil, url: nil, api_key: nil, region: nil, headers: nil, serializer: nil, path: nil, params: {}, preprocessors: nil, timeout: nil, max_tool_iterations: nil)
      preset_config = preset ? Presets.fetch(preset) : nil
      options = {
        preset_config: preset_config,
        url: url,
        region: region,
        headers: headers,
        serializer: serializer,
        path: path,
        params: params,
        preprocessors: preprocessors,
        timeout: timeout,
        max_tool_iterations: max_tool_iterations
      }

      options[:api_key_header] = api_key_header(name, api_key, preset_config || {}) if api_key

      @providers[name.to_s] = if options.values.any? { |value| value.respond_to?(:call) }
        {deferred: options}
      else
        build_provider_config(options)
      end
    end

    # Look up a registered provider by name. A provider registered with
    # callable arguments is resolved on every lookup: each callable is called
    # and the provider config is rebuilt from the results.
    #
    # @param name [Symbol, String] Provider name
    # @return [Hash, nil] Provider config hash
    def lookup(name)
      entry = @providers[name&.to_s]
      return entry unless entry&.key?(:deferred)

      resolved = entry[:deferred].transform_values do |value|
        value.respond_to?(:call) ? value.call : value
      end
      build_provider_config(resolved)
    end

    # All registered provider names.
    #
    # @return [Array<String>] the provider names
    def provider_names
      @providers.keys
    end

    # Configure automatic offloading of large sessions to a PatientHttp payload
    # store instead of carrying them through the job queue inline. Sessions whose
    # serialized size exceeds the threshold are written to the store and passed
    # by reference.
    #
    # @param payload_store [Symbol, String] Name of a payload store registered on
    #   the PatientHttp configuration
    # @param threshold [Integer] Size in bytes above which sessions are offloaded
    # @return [void]
    def session_offload(payload_store:, threshold: 65_536)
      raise ArgumentError, "threshold must be a positive Integer" unless threshold.is_a?(Integer) && threshold.positive?

      @session_offload_options = {payload_store: payload_store.to_s, threshold: threshold}
    end

    private

    # Build a provider config hash from registration options. Runs at
    # registration time for static options and at lookup time for options with
    # callable values (after the callables have been resolved), so validation
    # of a callable's result happens when the provider is used.
    def build_provider_config(options)
      preset_config = options[:preset_config] || {}

      resolved_url = options[:url] || (options[:preset_config] ? Presets.url(preset_config, region: options[:region]) : nil)

      resolved_serializer = (options[:serializer] || preset_config[:serializer] || :chat_completion).to_sym
      unless PatientLLM::VALID_SERIALIZERS.include?(resolved_serializer)
        raise ArgumentError, "Unknown serializer: #{resolved_serializer.inspect}. Valid options: #{PatientLLM::VALID_SERIALIZERS.map(&:inspect).join(", ")}"
      end

      resolved_headers = (preset_config[:headers] || {}).merge(options[:headers] || {})
      if options[:api_key_header]
        auth_header, secret_reference = options[:api_key_header]
        resolved_headers = {auth_header => secret_reference}.merge(resolved_headers)
      end

      ensure_auth_headers_use_secrets!(resolved_headers)

      {
        url: resolved_url,
        headers: resolved_headers,
        serializer: resolved_serializer,
        path: options[:path] || preset_config[:path],
        params: options[:params] || {},
        preprocessors: options[:preprocessors],
        timeout: options[:timeout],
        max_tool_iterations: options[:max_tool_iterations]
      }
    end

    # Build the authentication header for an api_key option. Returns the header
    # name and a SecretReference. Unless the api_key is already a SecretReference,
    # the key is registered with PatientHttp under a name derived from the
    # provider name, with the preset's auth format (e.g. "Bearer %s") applied
    # inside the registered block so formatting happens on the processor side.
    def api_key_header(provider_name, api_key, preset_config)
      auth_header = preset_config[:auth_header]
      raise ArgumentError, "api_key requires a preset that defines an authentication header" unless auth_header

      if api_key.is_a?(PatientHttp::SecretReference)
        return [auth_header, api_key]
      end

      unless api_key.respond_to?(:call) || api_key.is_a?(String)
        raise ArgumentError, "api_key must be a Proc, String, or PatientHttp::SecretReference"
      end

      auth_format = preset_config[:auth_format] || "%s"
      secret_name = "#{SECRET_NAME_PREFIX}.#{provider_name}.api_key"
      PatientHttp.register_secret(secret_name) do
        value = api_key.respond_to?(:call) ? api_key.call : api_key
        format(auth_format, value)
      end

      [auth_header, PatientHttp.secret(secret_name)]
    end

    def ensure_auth_headers_use_secrets!(headers)
      headers.each do |header_name, header_value|
        normalized_header_name = header_name.to_s.downcase
        next unless AUTHENTICATION_HEADERS.include?(normalized_header_name)

        if header_value && !header_value.is_a?(PatientHttp::SecretReference)
          raise ArgumentError, "Authentication header #{header_name} must be set up as a secret using `PatientHttp.secret`"
        end
      end
    end
  end
end
