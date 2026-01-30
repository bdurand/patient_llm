# frozen_string_literal: true

module Sidekiq
  module AsyncLlm
    # Sidekiq server middleware that processes async LLM responses.
    #
    # This middleware intercepts jobs from completion and error workers,
    # deserializes the Chat object from callback_args, and converts the
    # HTTP response to a parsed RubyLLM response.
    #
    # For completion callbacks, the job args are transformed to: [chat, response]
    # For error callbacks, the job args are transformed to: [chat, error]
    class Middleware
      include Sidekiq::ServerMiddleware

      def call(worker, job, queue)
        Sidekiq.logger.debug("AsyncLlm::Middleware processing job: #{job['class']}")
        Sidekiq.logger.debug("AsyncLlm::Middleware args count: #{job['args']&.size}")
        Sidekiq.logger.debug("AsyncLlm::Middleware first arg class: #{job['args']&.first&.class}")

        process_async_llm_callback(job)

        Sidekiq.logger.debug("AsyncLlm::Middleware after processing, args count: #{job['args']&.size}")
        Sidekiq.logger.debug("AsyncLlm::Middleware after processing, first arg class: #{job['args']&.first&.class}")

        yield
      rescue => e
        Sidekiq.logger.error("AsyncLlm Middleware error: #{e.class} - #{e.message}")
        Sidekiq.logger.error(e.backtrace&.first(5)&.join("\n"))
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
        Sidekiq.logger.debug("AsyncLlm::Middleware.process_completion called")

        # Get chat data from callback_args
        callback_args = response.callback_args
        Sidekiq.logger.debug("AsyncLlm::Middleware callback_args keys: #{callback_args.keys.inspect}")

        unless callback_args.include?(:chat)
          Sidekiq.logger.debug("AsyncLlm::Middleware no :chat key found, returning early")
          return
        end

        chat_data = callback_args.fetch(:chat, nil)
        Sidekiq.logger.debug("AsyncLlm::Middleware chat_data class: #{chat_data.class}")

        unless chat_data.is_a?(Hash)
          Sidekiq.logger.debug("AsyncLlm::Middleware chat_data is not a Hash, returning early")
          return
        end

        provider_slug = callback_args.fetch(:provider, nil)
        model_id = callback_args.fetch(:model, nil)
        Sidekiq.logger.debug("AsyncLlm::Middleware provider: #{provider_slug}, model: #{model_id}")

        chat = Chat.load(chat_data)
        Sidekiq.logger.debug("AsyncLlm::Middleware chat loaded: #{chat.class}")

        # Build a Faraday-like response for the provider
        faraday_response = Faraday::SidekiqAsyncHttp.to_faraday_response(response)
        Sidekiq.logger.debug("AsyncLlm::Middleware faraday_response built, body class: #{faraday_response.body.class}")

        # Get the provider instance
        _, provider_instance = RubyLLM::Models.resolve(model_id, provider: provider_slug, assume_exists: true)
        Sidekiq.logger.debug("AsyncLlm::Middleware provider_instance: #{provider_instance.class}")

        # Parse the response using the provider (method is private)
        message = provider_instance.send(:parse_completion_response, faraday_response)
        Sidekiq.logger.debug("AsyncLlm::Middleware message parsed: #{message.class}")

        Sidekiq.logger.debug("AsyncLlm::Middleware replacing args with [#{chat.class}, #{message.class}, metadata]")
        job["args"] = [response, chat, message]
        Sidekiq.logger.debug("AsyncLlm::Middleware args replaced, new count: #{job['args'].size}")
      end

      def process_error(job, error)
        # Get chat data from callback_args
        callback_args = error.callback_args
        return unless callback_args.include?(:chat)

        chat_data = callback_args.fetch(:chat, nil)
        return unless chat_data.is_a?(Hash)

        chat = Chat.load(chat_data)

        job["args"] = [error, chat]
      end
    end
  end
end
