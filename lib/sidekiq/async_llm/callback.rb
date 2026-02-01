# frozen_string_literal: true

module Sidekiq::AsyncLLM
  # Callback class for handling async LLM responses.
  class Callback
    def on_complete(response)
      callback_args = response.callback_args
      chat = Chat.load(callback_args[:chat])
      provider_slug = chat.provider
      model_id = chat.model

      # Build a Faraday-like response for the provider
      faraday_response = to_faraday_response(response)

      provider_instance = lookup_provider_instance(model_id, provider_slug)

      # Parse the response using the provider (method is private)
      message = provider_instance.send(:parse_completion_response, faraday_response)

      callback = chat_callback(callback_args)
      callback.on_complete(chat, message, chat_callback_args(callback_args), response)
    end

    def on_error(error)
      callback_args = error.callback_args
      chat = Chat.load(callback_args[:chat])
      callback = chat_callback(callback_args)
      callback.on_error(chat, chat_callback_args(callback_args), error)
    end

    private

    # Convert a Sidekiq::AsyncHTTP::Response to a Faraday::Response.
    #
    # @param response [Sidekiq::AsyncHttp::Response] The async response to convert.
    # @return [Faraday::Response] A Faraday response object.
    def to_faraday_response(response)
      env = Faraday::Env.new
      env.method = response.http_method
      env.url = URI(response.url)
      env.status = response.status
      env.response_headers = response.headers.to_h
      env.response_body = response.json? ? response.json : response.body

      Faraday::Response.new(env)
    end

    def lookup_provider_instance(model_id, provider_slug)
      _, provider_instance = RubyLLM::Models.resolve(model_id, provider: provider_slug, assume_exists: true)
      provider_instance
    end

    def chat_callback(callback_args)
      callback_class = Sidekiq::AsyncHttp::ClassHelper.resolve_class_name(callback_args[:chat_callback])
      callback_class.new
    end

    def chat_callback_args(callback_args)
      Sidekiq::AsyncHttp::CallbackArgs.new(callback_args[:custom])
    end
  end
end
