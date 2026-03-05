# frozen_string_literal: true

require "ruby_llm"
require "patient_http"

require_relative "llm/chat"
require_relative "llm/callback"

module PatientHttp
  module LLM
    VERSION = File.read(File.join(__dir__, "../../VERSION")).strip
  end
end
