# frozen_string_literal: true

require "patient_http"
require "prompt_builder"

module PatientLLM
  VERSION = File.read(File.join(__dir__, "../VERSION")).strip

  autoload :Configuration, File.expand_path("patient_llm/configuration", __dir__)
  autoload :HaltError, File.expand_path("patient_llm/halt_error", __dir__)
  autoload :Callback, File.expand_path("patient_llm/callback", __dir__)

  # Default API paths per serializer format.
  SERIALIZER_PATHS = {
    chat_completion: "/v1/chat/completions",
    open_responses: "/v1/responses",
    messages: "/v1/messages"
  }.freeze

  # Required version header for the Anthropic Messages API.
  ANTHROPIC_VERSION = "2023-06-01"

  # Valid serializer format names.
  VALID_SERIALIZERS = SERIALIZER_PATHS.keys.freeze

  class << self
    # Configure providers for LLM requests.
    #
    # @yield [Configuration]
    # @return [void]
    def configure
      @configuration ||= Configuration.new
      yield @configuration
    end

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

    # Send an LLM request asynchronously using the given session and provider.
    #
    # @param session [PromptBuilder::Session] The prompt session containing conversation state
    # @param provider [Symbol, String] Registered provider name
    # @param callback [Class, String] Callback class for handling completion/error
    # @param callback_args [Hash] Custom arguments passed through to the callback
    # @param url [String, nil] Override the provider's base URL for this request
    # @param serializer [Symbol, nil] Override the provider's serializer for this request
    # @param completion_path [String, nil] Override the endpoint path for this request
    # @param headers [Hash, nil] Additional headers merged on top of provider headers
    # @param params [Hash, nil] Additional params merged into the request payload
    # @return [Object] Handler-specific identifier for the enqueued request
    def ask(session, provider:, callback:, callback_args: {}, url: nil, serializer: nil, completion_path: nil, headers: nil, params: nil, tool_iteration: 0) # :nodoc: tool_iteration is internal
      provider_config = self.provider(provider) || {}
      provider_name = provider.to_s

      resolved_url = url || provider_config[:url]
      raise ArgumentError, "No API base URL configured. Set url: or register a provider with a url." unless resolved_url

      resolved_serializer = (serializer || provider_config[:serializer] || :chat_completion).to_sym
      validate_serializer!(resolved_serializer)
      resolved_completion_path = completion_path || provider_config[:completion_path] || SERIALIZER_PATHS[resolved_serializer] || "/v1/chat/completions"
      resolved_headers = (provider_config[:headers] || {}).merge(headers || {})
      if resolved_serializer == :messages && !resolved_headers.key?("anthropic-version")
        resolved_headers = {"anthropic-version" => ANTHROPIC_VERSION}.merge(resolved_headers)
      end
      resolved_params = (provider_config[:params] || {}).merge(params || {})

      payload = session.request_payload(resolved_serializer)
      payload = deep_merge(payload, deep_stringify_keys(resolved_params)) unless resolved_params.empty?

      request_url = join_url(resolved_url, resolved_completion_path)

      request_options = {}
      request_options["url"] = url if url
      request_options["serializer"] = serializer.to_s if serializer
      request_options["completion_path"] = completion_path if completion_path
      request_options["headers"] = headers if headers && !headers.empty?
      request_options["params"] = params if params && !params.empty?

      PatientHttp.post(
        request_url,
        json: payload,
        headers: resolved_headers,
        raise_error_responses: true,
        callback: PatientLLM::Callback,
        callback_args: {
          session: session.to_h,
          provider: provider_name,
          callback: callback.to_s,
          custom: callback_args,
          request_options: request_options,
          tool_iteration: tool_iteration
        }
      )
    end

    private

    def validate_serializer!(serializer)
      unless VALID_SERIALIZERS.include?(serializer)
        raise ArgumentError, "Unknown serializer: #{serializer.inspect}. Valid options: #{VALID_SERIALIZERS.map(&:inspect).join(", ")}"
      end
    end

    def join_url(base, path)
      "#{base.sub(%r{/\z}, "")}/#{path.to_s.sub(%r{\A/}, "")}"
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
