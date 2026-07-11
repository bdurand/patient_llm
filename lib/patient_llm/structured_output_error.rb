# frozen_string_literal: true

module PatientLLM
  # Raised when an agent declares an output schema but the model's response
  # cannot be parsed as JSON. The unparseable text is available on the error.
  class StructuredOutputError < StandardError
    # @return [String, nil] the raw response text that failed to parse
    attr_reader :text

    def initialize(message, text: nil)
      super(message)
      @text = text
    end
  end
end
