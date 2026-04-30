# frozen_string_literal: true

module PatientLLM
  # Raised by a tool handler to short-circuit the auto-execution loop.
  # The +content+ is delivered to the user callback as the final assistant
  # message.
  #
  # @example
  #   PromptBuilder.register_tool("stop", description: "Stop") do |args|
  #     raise PatientLLM::HaltError.new(content: "Done!")
  #   end
  class HaltError < StandardError
    # @return [String, nil] Content to surface as the assistant response
    attr_reader :content

    # @param content [String, nil] The content for the final assistant message
    # @param message [String] Optional error message (defaults to "Tool halted execution")
    def initialize(content: nil, message: "Tool halted execution")
      @content = content
      super(message)
    end
  end
end
