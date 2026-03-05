# frozen_string_literal: true

require "bundler/setup"

require_relative "../lib/patient_http-llm"

# Mock callback class for testing
class TestCallback
  def on_complete(chat, message, callback_args, response)
  end

  def on_error(chat, callback_args, error)
  end
end

# Test tool that returns a simple string result
class WeatherTool < RubyLLM::Tool
  description "Get the current weather for a city"
  param :city, desc: "The city name"

  def execute(city:)
    "72°F and sunny in #{city}"
  end
end

# Test tool that returns a hash result
class CalculatorTool < RubyLLM::Tool
  description "Perform basic math"
  param :expression, desc: "Math expression to evaluate"

  def execute(expression:)
    {result: eval(expression).to_s} # rubocop:disable Security/Eval
  end
end

# Test tool that halts the conversation
class HaltingTool < RubyLLM::Tool
  description "A tool that halts"
  param :reason, desc: "Reason to halt"

  def execute(reason:)
    halt("Halted: #{reason}")
  end
end

# Configure RubyLLM with fake API keys for testing
RubyLLM.configure do |config|
  config.openai_api_key = "test-key"
  config.anthropic_api_key = "test-key"
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.default_formatter = "doc" if config.files_to_run.one?
  config.order = :random
  Kernel.srand config.seed
end
