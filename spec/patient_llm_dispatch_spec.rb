# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM, "dispatch options" do
  let(:session) do
    PromptBuilder::Session.new(model: "gpt-4", max_output_tokens: 1000).tap { |s| s.user("Hello") }
  end

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

  describe "serializer binding" do
    it "records the resolved serializer in callback_args" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.call[:callback_args][:serializer]).to eq("chat_completion")
      end
    end

    it "records serializer overrides in callback_args" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", serializer: :messages)
        expect(captured.call[:callback_args][:serializer]).to eq("messages")
      end
    end
  end

  describe "timeout" do
    it "passes an ask timeout to the request" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", timeout: 600)
        expect(captured.call[:request].timeout).to eq(600)
      end
    end

    it "uses the provider's timeout by default" do
      PatientLLM.configure do |c|
        c.provider :slow, url: "https://slow.example.com", timeout: 300
      end

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :slow, callback: "TestCallback")
        expect(captured.call[:request].timeout).to eq(300)
      end
    end

    it "prefers the ask timeout over the provider's" do
      PatientLLM.configure do |c|
        c.provider :slow, url: "https://slow.example.com", timeout: 300
      end

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :slow, callback: "TestCallback", timeout: 45)
        expect(captured.call[:request].timeout).to eq(45)
      end
    end
  end

  describe "processor" do
    after do
      PatientLLM.configuration.processor = nil
    end

    it "sends nil by default" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.call[:request].processor).to be_nil
      end
    end

    it "passes an ask processor to the request" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", processor: :llm)
        expect(captured.call[:request].processor).to eq("llm")
      end
    end

    it "uses the configured processor by default" do
      PatientLLM.configure { |c| c.processor = :llm }

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.call[:request].processor).to eq("llm")
      end
    end

    it "resolves a callable configured processor on every request" do
      name = "llm"
      PatientLLM.configure { |c| c.processor = -> { name } }

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.call[:request].processor).to eq("llm")

        name = "webhooks"
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.call[:request].processor).to eq("webhooks")
      end
    end

    it "prefers the ask processor over the configured one" do
      PatientLLM.configure { |c| c.processor = :webhooks }

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", processor: :llm)
        expect(captured.call[:request].processor).to eq("llm")
      end
    end
  end

  describe "max_tool_iterations" do
    it "defaults to the Callback constant" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.call[:callback_args][:max_tool_iterations]).to eq(PatientLLM::Callback::MAX_TOOL_ITERATIONS)
      end
    end

    it "uses the provider's setting" do
      PatientLLM.configure do |c|
        c.provider :toolsy, url: "https://example.com", max_tool_iterations: 25
      end

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :toolsy, callback: "TestCallback")
        expect(captured.call[:callback_args][:max_tool_iterations]).to eq(25)
      end
    end

    it "prefers the ask override" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback", max_tool_iterations: 3)
        expect(captured.call[:callback_args][:max_tool_iterations]).to eq(3)
      end
    end
  end

  describe "session offload" do
    # In-memory payload store for testing
    let(:store_class) do
      Class.new(PatientHttp::PayloadStore::Base) do
        def initialize(**)
          @data = {}
        end

        attr_reader :data

        def store(key, data)
          @data[key] = JSON.generate(data)
          key
        end

        def fetch(key)
          json = @data[key]
          json && JSON.parse(json)
        end

        def delete(key)
          @data.delete(key)
          true
        end
      end
    end

    let(:patient_http_config) { PatientHttp::Configuration.new }

    before do
      stub_const("TestMemoryStore", store_class)
      PatientHttp::PayloadStore::Base.register(:test_memory, TestMemoryStore)
      patient_http_config.register_payload_store(:session_store, adapter: :test_memory)
      PatientHttp.default_configuration = patient_http_config
      PatientLLM.configure do |c|
        c.session_offload payload_store: :session_store, threshold: 50
      end
    end

    after do
      PatientHttp.default_configuration = nil
      PatientLLM.reset!
      PatientLLM.configure do |c|
        c.provider :openai,
          url: "https://api.openai.com",
          headers: {"Authorization" => PatientHttp.secret("openai.api_key")},
          serializer: :chat_completion
      end
    end

    it "replaces large sessions with a payload store reference" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")

        session_args = captured.call[:callback_args][:session]
        expect(session_args.keys).to eq([PatientLLM::SESSION_REF_KEY])
        expect(session_args[PatientLLM::SESSION_REF_KEY]["payload_store"]).to eq("session_store")
        expect(session_args[PatientLLM::SESSION_REF_KEY]["key"]).to start_with("patient_llm/session/")
      end
    end

    it "restores offloaded sessions in the callback" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")

        response = PatientHttp::Response.new(
          callback_args: captured.call[:callback_args],
          http_method: :post,
          url: "https://api.openai.com/v1/chat/completions",
          status: 200,
          headers: {"content-type" => "application/json"},
          body: '{"model":"gpt-4","choices":[{"message":{"role":"assistant","content":"hi"}}]}',
          duration: 1.0,
          request_id: SecureRandom.uuid
        )

        test_callback = TestCallback.new
        allow(TestCallback).to receive(:new).and_return(test_callback)
        allow(test_callback).to receive(:on_complete)

        PatientLLM::Callback.new.on_complete(response)

        expect(test_callback).to have_received(:on_complete) do |session:, **|
          expect(session.model).to eq("gpt-4")
          expect(session.items).not_to be_empty
        end
      end
    end

    it "does not offload sessions under the threshold" do
      PatientLLM.configure do |c|
        c.session_offload payload_store: :session_store, threshold: 1_000_000
      end

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        expect(captured.call[:callback_args][:session]).to have_key("model")
      end
    end

    it "raises when the payload store is not registered" do
      PatientLLM.configure do |c|
        c.session_offload payload_store: :nonexistent_store, threshold: 50
      end

      with_fake_handler do
        expect {
          PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
        }.to raise_error(ArgumentError, /not registered/)
      end
    end
  end

  describe "inline execution" do
    it "executes the request synchronously inside an inline block" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 200, headers: {"content-type" => "application/json"}, body: '{"model":"gpt-4","choices":[{"message":{"role":"assistant","content":"inline hi"}}]}')

      received = nil
      test_callback = TestCallback.new
      allow(TestCallback).to receive(:new).and_return(test_callback)
      allow(test_callback).to receive(:on_complete) do |llm_response:, **|
        received = llm_response.text
      end

      PatientLLM.inline do
        PatientLLM.ask(session, provider: :openai, callback: "TestCallback")
      end

      expect(received).to eq("inline hi")
    end
  end
end
