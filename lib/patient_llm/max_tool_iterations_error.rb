# frozen_string_literal: true

module PatientLLM
  # Raised internally when the automatic tool-execution loop exceeds
  # {Callback::MAX_TOOL_ITERATIONS}. It is wrapped in a
  # `PatientHttp::RequestError` (with error type +:max_tool_iterations+) and
  # delivered to the user callback's +on_error+ method rather than propagating
  # out of the callback worker.
  class MaxToolIterationsError < StandardError
  end
end
