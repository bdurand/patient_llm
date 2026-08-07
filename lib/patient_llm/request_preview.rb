# frozen_string_literal: true

module PatientLLM
  # The request that {PatientLLM.ask} would send, as returned by
  # {PatientLLM.preview_request} and {Agent.preview_request}. Header values
  # that reference registered secrets are replaced with placeholder strings.
  #
  # @!attribute [r] url
  #   @return [String] The fully resolved request URL
  # @!attribute [r] headers
  #   @return [Hash] The request headers, with secret values redacted
  # @!attribute [r] payload
  #   @return [Hash] The JSON request payload
  RequestPreview = Data.define(:url, :headers, :payload)
end
