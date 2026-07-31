# frozen_string_literal: true

module PatientLLM
  # Signals that the automatic tool-execution loop exceeded the resolved
  # max_tool_iterations limit (default {Callback::MAX_TOOL_ITERATIONS}). It is
  # never raised directly; it is wrapped in a `PatientHttp::RequestError` (with
  # error type +:max_tool_iterations+) and delivered to the user callback's
  # +on_error+ method.
  class MaxToolIterationsError < StandardError
  end
end
