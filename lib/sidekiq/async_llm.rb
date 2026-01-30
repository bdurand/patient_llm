# frozen_string_literal: true

require "sidekiq"
require "json"
require "ruby_llm"
require "faraday/sidekiq_async_http"

require_relative "async_llm/chat"
require_relative "async_llm/middleware"

module Sidekiq
  module AsyncLlm
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

    class Error < StandardError; end

    class << self
      # Configure the Sidekiq server middleware.
      # Call this in your Sidekiq initializer:
      #
      #   Sidekiq.configure_server do |config|
      #     Sidekiq::AsyncLlm.configure_middleware(config)
      #   end
      def configure_middleware(config)
        config.server_middleware do |chain|
          chain.add Middleware
        end
      end
    end
  end
end
