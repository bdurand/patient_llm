# frozen_string_literal: true

require "ruby_llm"
require "faraday/sidekiq_async_http"

require_relative "async_llm/chat"
require_relative "async_llm/middleware"

module Sidekiq
  module AsyncLLM
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip

    class Error < StandardError; end

    class << self
      # Configure the Sidekiq server middleware.
      def append_middleware
        Sidekiq::AsyncHttp.append_server_middleware

        Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add Middleware
          end
        end
      end
    end
  end
end

Sidekiq::AsyncLLM.append_middleware
