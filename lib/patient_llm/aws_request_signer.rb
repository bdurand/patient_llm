# frozen_string_literal: true

module PatientLLM
  # Signs outgoing requests with an AWS SigV4 signature. Instances are
  # callable, so one can be registered directly as a PatientHttp request
  # preprocessor for providers that require request signing (AWS Bedrock):
  #
  # @example
  #   PatientHttp::Sidekiq.configure do |config|
  #     config.register_preprocessor(:aws_sigv4, PatientLLM::AwsRequestSigner.new(
  #       credentials: Aws::CredentialProviderChain.new
  #     ))
  #   end
  #
  # The credentials can be given as a credential chain (any object responding
  # to +resolve+, e.g. +Aws::CredentialProviderChain+), a credentials provider
  # (responding to +credentials+), or a static credentials object (responding
  # to +access_key_id+ and +secret_access_key+, e.g. +Aws::Credentials+).
  # A chain is resolved lazily on the first request and the resolved provider
  # is reused thereafter.
  #
  # The signing service and region can be passed explicitly; when omitted they
  # are derived from each request's URL host for standard
  # +<service>.<region>.<dns-suffix>+ endpoints, including dual-stack
  # +api.aws+ hosts (e.g. +bedrock-runtime.us-east-1.amazonaws.com+ signs as
  # service "bedrock" and +bedrock-mantle.us-east-1.api.aws+ as
  # "bedrock-mantle", both in region "us-east-1").
  #
  # Only a whitelist of request headers is signed (see
  # {DEFAULT_SIGNED_HEADERS}; override with signed_headers:) because
  # intermediaries commonly rewrite other headers in transit — the Bedrock
  # Mantle gateway, for one, replaces x-request-id before validating the
  # signature. The signature also covers a host header derived from the
  # request URL, but the host header itself is never set on the request — the
  # HTTP client generates its own from the URL, and sending both would
  # invalidate the signature.
  #
  # The aws-sigv4 gem must be loaded for this class to work, but it is not a
  # dependency of this gem; add it to your bundle (it is included with the
  # aws-sdk-core gem).
  class AwsRequestSigner
    # Matches AWS region host labels like "us-east-1" or "us-gov-west-1".
    REGION_PATTERN = /\A[a-z]{2}(?:-gov|-iso[a-z]?)?-[a-z]+-\d+\z/

    # DNS suffixes used by AWS endpoint hosts: the standard and China suffixes
    # plus their dual-stack equivalents.
    AWS_DNS_SUFFIXES = [
      ".amazonaws.com",
      ".api.aws",
      ".amazonaws.com.cn",
      ".api.amazonwebservices.com.cn"
    ].freeze

    # Endpoint host labels whose SigV4 signing name differs from the label.
    # Note that bedrock-mantle is intentionally absent: the Mantle endpoint
    # signs under its own "bedrock-mantle" service name.
    SIGNING_NAME_ALIASES = {
      "bedrock-runtime" => "bedrock",
      "bedrock-agent-runtime" => "bedrock"
    }.freeze

    # Request headers included in the signature by default. Signing is
    # whitelist-based because proxies and gateways commonly rewrite other
    # headers in transit (the Bedrock Mantle gateway replaces x-request-id
    # with its own id before validating the signature), which would
    # invalidate any signature that covers them. The signer itself always
    # adds and signs host, x-amz-date, x-amz-content-sha256, and
    # x-amz-security-token.
    DEFAULT_SIGNED_HEADERS = ["content-type", "anthropic-version"].freeze

    # @param credentials [Object] a credential chain (responds to +resolve+),
    #   a credentials provider (responds to +credentials+), or a credentials
    #   object (responds to +access_key_id+ and +secret_access_key+)
    # @param service [String, nil] the SigV4 signing name (e.g. "bedrock");
    #   derived from the request URL host when nil
    # @param region [String, nil] the AWS region (e.g. "us-east-1"); derived
    #   from the request URL host when nil
    # @param signed_headers [Array<String>] request header names included in
    #   the signature when present; defaults to {DEFAULT_SIGNED_HEADERS}
    # @raise [LoadError] if the aws-sigv4 gem is not loaded
    # @raise [ArgumentError] if the credentials do not respond to any of the
    #   supported interfaces
    def initialize(credentials:, service: nil, region: nil, signed_headers: DEFAULT_SIGNED_HEADERS)
      unless defined?(Aws::Sigv4::Signer)
        raise LoadError, "#{self.class.name} requires the aws-sigv4 gem, which is not a dependency of patient_llm. Add `gem \"aws-sigv4\"` to your Gemfile and require \"aws-sigv4\" (the gem is included with aws-sdk-core)."
      end

      supported = credentials.respond_to?(:resolve) ||
        credentials.respond_to?(:credentials) ||
        (credentials.respond_to?(:access_key_id) && credentials.respond_to?(:secret_access_key))
      unless supported
        raise ArgumentError, "credentials must be a credential chain (responds to resolve), a credentials provider (responds to credentials), or a credentials object (responds to access_key_id and secret_access_key)"
      end

      @credentials = credentials
      @service = service
      @region = region
      @signed_headers = signed_headers.map { |name| name.to_s.downcase }
      @signer = nil
      @resolved_provider = nil
      @mutex = Mutex.new
    end

    # Sign the outgoing request, adding the SigV4 signature headers to it.
    #
    # @param request [PatientHttp::OutgoingRequest] the request about to be sent
    # @return [void]
    # @raise [ArgumentError] if the service or region was not given and cannot
    #   be derived from the request URL host
    def call(request)
      signature = signer(request.url).sign_request(
        http_method: request.http_method.to_s.upcase,
        url: request.url,
        headers: request.headers.to_h.slice(*@signed_headers),
        body: request.body.to_s
      )
      # The signature covers a host header derived from the URL, but it must
      # not be set on the request: the HTTP client generates its own Host
      # header from the URL, and sending both makes the server canonicalize a
      # doubled value that can never match the signature.
      signature.headers.each do |name, value|
        request.headers[name] = value unless name == "host"
      end
    end

    private

    # The signer can only be cached when both the service and region are fixed
    # at construction time; otherwise they depend on each request's URL host.
    def signer(url)
      return @signer if @signer

      host = URI.parse(url).host
      service, region = resolve_service_and_region(host)

      signer = Aws::Sigv4::Signer.new(service: service, region: region, **credentials_options)
      @signer = signer if @service && @region
      signer
    end

    def resolve_service_and_region(host)
      return [@service, @region] if @service && @region

      derived_service, derived_region = derive_from_host(host)
      service = @service || derived_service
      region = @region || derived_region

      unless service
        raise ArgumentError, "Could not derive the AWS service from the request host #{host.inspect}. Pass service: to #{self.class.name}."
      end
      unless region
        raise ArgumentError, "Could not derive the AWS region from the request host #{host.inspect}. Pass region: to #{self.class.name}."
      end

      [service, region]
    end

    # Derive [service, region] from hosts like
    # "bedrock-runtime.us-east-1.amazonaws.com" or
    # "bedrock-mantle.us-east-1.api.aws": the region is the label matching
    # REGION_PATTERN and the service is the label before it, with any "-fips"
    # suffix stripped and known signing-name aliases applied (bedrock-runtime
    # and bedrock-agent-runtime sign as "bedrock"; bedrock-mantle signs under
    # its own name).
    def derive_from_host(host)
      host = host.to_s.downcase
      return [nil, nil] unless AWS_DNS_SUFFIXES.any? { |suffix| host.end_with?(suffix) }

      labels = host.split(".")
      region_index = labels.index { |label| REGION_PATTERN.match?(label) }
      return [nil, nil] unless region_index&.positive?

      service = labels[region_index - 1].delete_suffix("-fips")
      service = SIGNING_NAME_ALIASES.fetch(service, service)

      [service, labels[region_index]]
    end

    def credentials_options
      if @credentials.respond_to?(:resolve)
        {credentials_provider: resolved_provider}
      elsif @credentials.respond_to?(:credentials)
        {credentials_provider: @credentials}
      else
        {credentials: @credentials}
      end
    end

    def resolved_provider
      @mutex.synchronize do
        @resolved_provider ||= @credentials.resolve
      end || raise(ArgumentError, "AWS credential chain #{@credentials.class.name} did not resolve any credentials")
    end
  end
end
