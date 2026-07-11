# frozen_string_literal: true

require "spec_helper"

require "aws-sigv4"

RSpec.describe PatientLLM::AwsRequestSigner do
  let(:static_credentials) do
    Struct.new(:access_key_id, :secret_access_key, :session_token).new("AKIDEXAMPLE", "secret", nil)
  end

  let(:credentials_provider) do
    creds = static_credentials
    provider = Object.new
    provider.define_singleton_method(:credentials) { creds }
    provider
  end

  def outgoing_request(url)
    PatientHttp::OutgoingRequest.new(
      http_method: :post,
      url: url,
      headers: PatientHttp::HttpHeaders.new("content-type" => "application/json"),
      body: '{"messages":[]}'
    )
  end

  describe "dependency check" do
    it "raises a helpful error when the aws-sigv4 gem is not loaded" do
      hide_const("Aws::Sigv4::Signer")
      expect {
        described_class.new(credentials: static_credentials)
      }.to raise_error(LoadError, /aws-sigv4/)
    end
  end

  describe "credentials validation" do
    it "accepts a static credentials object" do
      expect { described_class.new(credentials: static_credentials) }.not_to raise_error
    end

    it "accepts a credentials provider" do
      expect { described_class.new(credentials: credentials_provider) }.not_to raise_error
    end

    it "accepts a credential chain" do
      chain = double(resolve: credentials_provider)
      expect { described_class.new(credentials: chain) }.not_to raise_error
    end

    it "raises when the credentials do not respond to any supported interface" do
      expect {
        described_class.new(credentials: Object.new)
      }.to raise_error(ArgumentError, /credential chain.*credentials provider.*credentials object/)
    end
  end

  describe "#call" do
    it "adds SigV4 signature headers to the request" do
      signer = described_class.new(credentials: static_credentials, service: "bedrock", region: "us-east-1")
      request = outgoing_request("https://bedrock-runtime.us-east-1.amazonaws.com/model/my-model/converse")

      signer.call(request)

      expect(request.headers["authorization"]).to include("AWS4-HMAC-SHA256")
      expect(request.headers["authorization"]).to include("Credential=AKIDEXAMPLE/")
      expect(request.headers["authorization"]).to include("/us-east-1/bedrock/aws4_request")
      expect(request.headers["x-amz-date"]).to match(/\A\d{8}T\d{6}Z\z/)
      expect(request.headers["x-amz-content-sha256"]).to match(/\A\h{64}\z/)
    end

    it "signs with credentials from a credentials provider" do
      signer = described_class.new(credentials: credentials_provider, service: "bedrock", region: "us-east-1")
      request = outgoing_request("https://bedrock-runtime.us-east-1.amazonaws.com/model/my-model/converse")

      signer.call(request)

      expect(request.headers["authorization"]).to include("Credential=AKIDEXAMPLE/")
    end

    it "resolves a credential chain once and reuses the provider" do
      chain = double
      expect(chain).to receive(:resolve).once.and_return(credentials_provider)
      signer = described_class.new(credentials: chain, service: "bedrock", region: "us-east-1")

      2.times do
        request = outgoing_request("https://bedrock-runtime.us-east-1.amazonaws.com/model/my-model/converse")
        signer.call(request)
        expect(request.headers["authorization"]).to include("Credential=AKIDEXAMPLE/")
      end
    end

    it "raises when the credential chain does not resolve any credentials" do
      chain = double(resolve: nil)
      signer = described_class.new(credentials: chain, service: "bedrock", region: "us-east-1")
      request = outgoing_request("https://bedrock-runtime.us-east-1.amazonaws.com/model/my-model/converse")

      expect { signer.call(request) }.to raise_error(ArgumentError, /did not resolve any credentials/)
    end

    describe "deriving the service and region from the request host" do
      it "derives both from a standard endpoint host" do
        signer = described_class.new(credentials: static_credentials)
        request = outgoing_request("https://lambda.us-west-2.amazonaws.com/some/path")

        signer.call(request)

        expect(request.headers["authorization"]).to include("/us-west-2/lambda/aws4_request")
      end

      it "maps the bedrock-runtime host label to the bedrock signing name" do
        signer = described_class.new(credentials: static_credentials)
        request = outgoing_request("https://bedrock-runtime.us-east-1.amazonaws.com/model/my-model/converse")

        signer.call(request)

        expect(request.headers["authorization"]).to include("/us-east-1/bedrock/aws4_request")
      end

      it "strips a -fips suffix from the service label" do
        signer = described_class.new(credentials: static_credentials)
        request = outgoing_request("https://bedrock-runtime-fips.us-gov-west-1.amazonaws.com/model/my-model/converse")

        signer.call(request)

        expect(request.headers["authorization"]).to include("/us-gov-west-1/bedrock/aws4_request")
      end

      it "uses an explicit service with a derived region" do
        signer = described_class.new(credentials: static_credentials, service: "execute-api")
        request = outgoing_request("https://abc123.us-east-2.amazonaws.com/prod/chat")

        signer.call(request)

        expect(request.headers["authorization"]).to include("/us-east-2/execute-api/aws4_request")
      end

      it "uses an explicit region with a derived service" do
        signer = described_class.new(credentials: static_credentials, region: "eu-central-1")
        request = outgoing_request("https://bedrock-runtime.us-east-1.amazonaws.com/model/my-model/converse")

        signer.call(request)

        expect(request.headers["authorization"]).to include("/eu-central-1/bedrock/aws4_request")
      end

      it "raises a helpful error when the service cannot be derived" do
        signer = described_class.new(credentials: static_credentials, region: "us-east-1")
        request = outgoing_request("https://llm.example.com/v1/chat")

        expect { signer.call(request) }.to raise_error(ArgumentError, /Could not derive the AWS service.*llm\.example\.com.*Pass service:/m)
      end

      it "raises a helpful error when the region cannot be derived" do
        signer = described_class.new(credentials: static_credentials, service: "bedrock")
        request = outgoing_request("https://bedrock.amazonaws.com/model/my-model/converse")

        expect { signer.call(request) }.to raise_error(ArgumentError, /Could not derive the AWS region.*Pass region:/m)
      end
    end

    it "can be registered as a PatientHttp preprocessor" do
      configuration = PatientHttp::Configuration.new
      signer = described_class.new(credentials: static_credentials, service: "bedrock", region: "us-east-1")
      configuration.register_preprocessor(:aws_sigv4, signer)

      expect(configuration.preprocessor(:aws_sigv4)).to be(signer)
    end
  end
end
