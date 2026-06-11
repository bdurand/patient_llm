# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM do
  let(:session) do
    PromptBuilder::Session.new(model: "gpt-4").tap { |s| s.user("Hello") }
  end

  # Captures the request sent to PatientHttp and returns a fake request id.
  # Yields the captured request hash when the block is evaluated.
  def with_fake_handler
    captured = nil
    fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
      captured = {request: request, callback: callback, callback_args: callback_args, raise_error_responses: raise_error_responses}
      "req-id"
    }

    PatientHttp.register_handler(fake_handler)
    begin
      yield -> { captured }
    ensure
      PatientHttp.unregister_handler
    end
  end

  describe ".ask" do
    describe "URL resolution" do
      it "uses the provider's configured URL" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:request].url.to_s).to start_with("https://api.openai.com")
        end
      end

      it "uses the url override when provided" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", url: "https://custom.example.com")
          expect(captured.call[:request].url.to_s).to start_with("https://custom.example.com")
        end
      end

      it "raises ArgumentError when no URL is available" do
        expect {
          PatientLLM.ask(session, provider: :nonexistent, callback: "TestCallback")
        }.to raise_error(ArgumentError, /No API base URL configured/)
      end
    end

    describe "serializer resolution" do
      it "uses the provider's configured serializer" do
        PatientLLM.configure do |c|
          c.provider :anthropic_test, url: "https://api.anthropic.com", serializer: :messages
        end

        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :anthropic_test, callback: "TestCallback")
          expect(captured.call[:request].url.to_s).to include("/v1/messages")
        end
      end

      it "defaults to :chat_completion when provider has no serializer" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:request].url.to_s).to include("/v1/chat/completions")
        end
      end

      it "uses the serializer override" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :open_responses)
          expect(captured.call[:request].url.to_s).to include("/v1/responses")
        end
      end

      it "raises for an invalid serializer" do
        expect {
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :invalid)
        }.to raise_error(ArgumentError, /Unknown serializer.*:invalid/)
      end
    end

    describe "completion path resolution" do
      it "uses the default path for :chat_completion" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:request].url.to_s).to end_with("/v1/chat/completions")
        end
      end

      it "uses the default path for :messages" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :messages)
          expect(captured.call[:request].url.to_s).to end_with("/v1/messages")
        end
      end

      it "uses the default path for :open_responses" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :open_responses)
          expect(captured.call[:request].url.to_s).to end_with("/v1/responses")
        end
      end

      it "uses the provider's path override" do
        PatientLLM.configure do |c|
          c.provider :custom_path_test, url: "https://custom.example.com", path: "/api/chat"
        end

        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :custom_path_test, callback: "TestCallback")
          expect(captured.call[:request].url.to_s).to end_with("/api/chat")
        end
      end

      it "uses the path argument override" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", path: "/custom/endpoint")
          expect(captured.call[:request].url.to_s).to end_with("/custom/endpoint")
        end
      end

      it "accepts the deprecated completion_path argument as an alias for path" do
        with_fake_handler do |captured|
          expect do
            PatientLLM.ask(session, provider: :openai, callback: "TestCallback", completion_path: "/custom/endpoint")
          end.to output(/completion_path.*deprecated/).to_stderr
          expect(captured.call[:request].url.to_s).to end_with("/custom/endpoint")
        end
      end
    end

    describe "header merging" do
      it "includes provider headers" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:request].headers["Authorization"]).to eq(PatientHttp.secret("openai.api_key"))
        end
      end

      it "merges request headers on top of provider headers" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", headers: {"X-Custom" => "value"})
          headers = captured.call[:request].headers
          expect(headers["Authorization"]).to eq(PatientHttp.secret("openai.api_key"))
          expect(headers["X-Custom"]).to eq("value")
        end
      end

      it "allows request headers to override provider headers" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", headers: {"Authorization" => "Bearer override"})
          expect(captured.call[:request].headers["Authorization"]).to eq("Bearer override")
        end
      end

      it "adds anthropic-version header for messages serializer" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :messages)
          expect(captured.call[:request].headers["anthropic-version"]).to eq("2023-06-01")
        end
      end

      it "does not override a user-supplied anthropic-version header" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :messages, headers: {"anthropic-version" => "2024-01-01"})
          expect(captured.call[:request].headers["anthropic-version"]).to eq("2024-01-01")
        end
      end

      it "does not add anthropic-version for non-messages serializers" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:request].headers["anthropic-version"]).to be_nil
        end
      end
    end

    describe "params merging" do
      it "merges provider params into the payload" do
        PatientLLM.configure do |c|
          c.provider :params_test, url: "https://example.com", params: {temperature: 0.5}
        end

        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :params_test, callback: "TestCallback")
          body = JSON.parse(captured.call[:request].body)
          expect(body["temperature"]).to eq(0.5)
        end
      end

      it "merges request params on top of provider params" do
        PatientLLM.configure do |c|
          c.provider :params_merge_test, url: "https://example.com", params: {temperature: 0.5}
        end

        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :params_merge_test, callback: "TestCallback", params: {max_tokens: 100})
          body = JSON.parse(captured.call[:request].body)
          expect(body["temperature"]).to eq(0.5)
          expect(body["max_tokens"]).to eq(100)
        end
      end

      it "allows request params to override provider params" do
        PatientLLM.configure do |c|
          c.provider :params_override_test, url: "https://example.com", params: {temperature: 0.5}
        end

        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :params_override_test, callback: "TestCallback", params: {temperature: 0.9})
          body = JSON.parse(captured.call[:request].body)
          expect(body["temperature"]).to eq(0.9)
        end
      end
    end

    describe "callback_args" do
      it "includes the serialized session" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          args = captured.call[:callback_args]
          expect(args[:session]).to be_a(Hash)
          expect(args[:session]["model"]).to eq("gpt-4")
        end
      end

      it "includes the provider name as a string" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:callback_args][:provider]).to eq("openai")
        end
      end

      it "includes the callback class name as a string" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:callback_args][:callback]).to eq("TestCallback")
        end
      end

      it "includes custom callback_args" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", callback_args: {user_id: "abc"})
          expect(captured.call[:callback_args][:custom]).to eq({"user_id" => "abc"})
        end
      end

      it "defaults custom callback_args to empty hash" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:callback_args][:custom]).to eq({})
        end
      end

      it "includes tool_iteration" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", tool_iteration: 3)
          expect(captured.call[:callback_args][:tool_iteration]).to eq(3)
        end
      end

      it "defaults tool_iteration to 0" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:callback_args][:tool_iteration]).to eq(0)
        end
      end
    end

    describe "request_options" do
      it "records url override in request_options" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", url: "https://override.example.com")
          options = captured.call[:callback_args][:request_options]
          expect(options["url"]).to eq("https://override.example.com")
        end
      end

      it "records serializer override in request_options" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :messages)
          options = captured.call[:callback_args][:request_options]
          expect(options["serializer"]).to eq("messages")
        end
      end

      it "records path override in request_options" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", path: "/custom")
          options = captured.call[:callback_args][:request_options]
          expect(options["path"]).to eq("/custom")
        end
      end

      it "records headers override in request_options" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", headers: {"X-Foo" => "bar"})
          options = captured.call[:callback_args][:request_options]
          expect(options["headers"]).to eq({"X-Foo" => "bar"})
        end
      end

      it "records params override in request_options" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", params: {top_p: 0.9})
          options = captured.call[:callback_args][:request_options]
          expect(options["params"]).to eq({top_p: 0.9})
        end
      end

      it "does not include url in request_options when not overridden" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          options = captured.call[:callback_args][:request_options]
          expect(options).not_to have_key("url")
        end
      end

      it "does not include serializer in request_options when not overridden" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          options = captured.call[:callback_args][:request_options]
          expect(options).not_to have_key("serializer")
        end
      end

      it "does not include empty headers in request_options" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", headers: {})
          options = captured.call[:callback_args][:request_options]
          expect(options).not_to have_key("headers")
        end
      end

      it "does not include empty params in request_options" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", params: {})
          options = captured.call[:callback_args][:request_options]
          expect(options).not_to have_key("params")
        end
      end
    end

    describe "PatientHttp.post arguments" do
      it "sets raise_error_responses to true" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:raise_error_responses]).to be true
        end
      end

      it "uses PatientLLM::Callback as the callback handler" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(captured.call[:callback]).to eq(PatientLLM::Callback)
        end
      end

      it "returns the handler result" do
        with_fake_handler do |_captured|
          result = PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          expect(result).to eq("req-id")
        end
      end
    end

    describe "URL joining" do
      it "joins base URL and path without double slashes" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", url: "https://example.com/", path: "/v1/chat")
          expect(captured.call[:request].url.to_s).to eq("https://example.com/v1/chat")
        end
      end

      it "handles base URL without trailing slash" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback", url: "https://example.com", path: "v1/chat")
          expect(captured.call[:request].url.to_s).to eq("https://example.com/v1/chat")
        end
      end

      it "embeds the session model in the default Gemini path" do
        gemini_session = PromptBuilder::Session.new(model: "gemini-2.5-pro").tap { |s| s.user("Hello") }
        with_fake_handler do |captured|
          PatientLLM.ask(gemini_session, provider: :gemini, callback: "TestCallback", serializer: :gemini, url: "https://generativelanguage.googleapis.com")
          expect(captured.call[:request].url.to_s).to eq("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent")
        end
      end
    end

    describe "payload" do
      it "serializes the session using the resolved serializer" do
        with_fake_handler do |captured|
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
          body = JSON.parse(captured.call[:request].body)
          expect(body).to have_key("model")
          expect(body["model"]).to eq("gpt-4")
        end
      end
    end
  end

  describe "constants" do
    it "defines SERIALIZER_PATHS for all valid serializers" do
      PatientLLM::VALID_SERIALIZERS.each do |serializer|
        expect(PatientLLM::SERIALIZER_PATHS).to have_key(serializer)
      end
    end

    it "defines ANTHROPIC_VERSION" do
      expect(PatientLLM::ANTHROPIC_VERSION).to eq("2023-06-01")
    end

    it "defines VERSION" do
      expect(PatientLLM::VERSION).to match(/\A\d+\.\d+\.\d+/)
    end
  end
end
