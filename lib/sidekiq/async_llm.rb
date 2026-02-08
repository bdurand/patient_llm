# frozen_string_literal: true

require "ruby_llm"
require "sidekiq-async_http"

require_relative "async_llm/chat"
require_relative "async_llm/callback"

module Sidekiq
  module AsyncLLM
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip
  end
end
