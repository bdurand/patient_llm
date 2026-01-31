# frozen_string_literal: true

module Sidekiq
  module AsyncLLM
    # Sidekiq server middleware that processes async LLM responses.
    #
    # This middleware intercepts jobs from completion and error workers,
    # deserializes the Chat object from callback_args, and converts the
    # HTTP response to a parsed RubyLLM response.
    #
    # For completion callbacks, the job args are transformed to: [response, chat, message, callback_args]
    # For error callbacks, the job args are transformed to: [error, chat, callback_args]
    class Middleware
      include Sidekiq::ServerMiddleware

      def call(worker, job, queue)
        process_async_llm_callback(job)

        yield
      rescue => e
        Sidekiq.logger.error("AsyncLLM Middleware error: #{e.class} - #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
        raise
      end

      private

      def process_async_llm_callback(job)
        args = job["args"]
        return unless args&.first

        first_arg = args.first

        if first_arg.is_a?(Sidekiq::AsyncHttp::Response)
          process_completion(job, first_arg)
        elsif first_arg.is_a?(Sidekiq::AsyncHttp::Error)
          process_error(job, first_arg)
        end
      end

      def process_completion(job, response)
        callback_args = response.callback_args

        unless callback_args.include?(:chat)
          Sidekiq.logger.warn("AsyncLLM::Middleware no :chat key found respoinse callback args")
          return
        end

        chat_data = callback_args.fetch(:chat, nil)
        unless chat_data.is_a?(Hash)
          Sidekiq.logger.warn("AsyncLLM::Middleware chat_data is not a Hash")
          return
        end

        provider_slug = callback_args.fetch(:provider, nil)
        model_id = callback_args.fetch(:model, nil)

        chat = Chat.load(chat_data)

        # Build a Faraday-like response for the provider
        faraday_response = Faraday::SidekiqAsyncHttp.to_faraday_response(response)

        # Get the provider instance
        _, provider_instance = RubyLLM::Models.resolve(model_id, provider: provider_slug, assume_exists: true)

        # Parse the response using the provider (method is private)
        message = provider_instance.send(:parse_completion_response, faraday_response)

        custom_callback_args = Sidekiq::AsyncHttp::CallbackArgs.new(callback_args.fetch(:custom, {}))

        job["args"] = [response, chat, message, custom_callback_args]
      end

      def process_error(job, error)
        # Get chat data from callback_args
        callback_args = error.callback_args
        return unless callback_args.include?(:chat)

        chat_data = callback_args.fetch(:chat, nil)
        return unless chat_data.is_a?(Hash)

        chat = Chat.load(chat_data)
        custom_callback_args = Sidekiq::AsyncHttp::CallbackArgs.new(callback_args.fetch(:custom, {}))

        job["args"] = [error, chat, custom_callback_args]
      end
    end
  end
end
