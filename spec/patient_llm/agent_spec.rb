# frozen_string_literal: true

require "spec_helper"

class TestTripAgent < PatientLLM::Agent
  provider :openai
  model "gpt-4"
  system "You are a travel assistant."
  instructions "Answer in one paragraph."
  temperature 0.3
  max_output_tokens 500
  max_tool_iterations 5
  extra guardrail_config: {guardrailIdentifier: "gr-1", guardrailVersion: "1"}

  tool :weather, "Get the weather for a city" do
    param :city, :string, "City name", required: true
    param :country, :string
  end

  output do
    field :summary, :string, required: true
    field :packing_list, array: :string
  end

  class << self
    attr_accessor :recorded
  end

  def weather(city:, country: nil, context: nil)
    self.class.recorded[:weather_args] = {city: city, country: country}
    self.class.recorded[:weather_context] = context&.to_h
    "72F in #{city}"
  end

  def completed(response)
    self.class.recorded[:completed] = response
    self.class.recorded[:completed_context] = response.context.to_h
  end

  def failed(failure)
    self.class.recorded[:failed] = failure
    self.class.recorded[:failed_context] = failure.context.to_h
  end

  def tool_round(response)
    self.class.recorded[:tool_rounds] ||= 0
    self.class.recorded[:tool_rounds] += 1
    self.class.recorded[:tool_round_response] = response
  end
end

class TestPlainAgent < PatientLLM::Agent
  provider :openai
  model "gpt-4"
end

class TestTripCallbacks
  class << self
    attr_accessor :recorded
  end

  def completed(response)
    self.class.recorded[:completed] = response
  end

  def failed(failure)
    self.class.recorded[:failed] = failure
  end

  def tool_round(response)
    self.class.recorded[:tool_rounds] ||= 0
    self.class.recorded[:tool_rounds] += 1
  end
end

class TestFailureOnlyCallbacks
  class << self
    attr_accessor :recorded
  end

  def failed(failure)
    self.class.recorded[:failed] = failure
  end
end

class TestAgentCallbacks < PatientLLM::Agent
  class << self
    attr_accessor :recorded
  end

  def completed(response)
    self.class.recorded[:completed] = response
    self.class.recorded[:session] = session
    self.class.recorded[:provider] = provider
  end
end

RSpec.describe PatientLLM::Agent do
  before do
    TestTripAgent.recorded = {}
    TestTripCallbacks.recorded = {}
    TestFailureOnlyCallbacks.recorded = {}
    TestAgentCallbacks.recorded = {}
  end

  def with_fake_handler
    captured = []
    fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
      captured << {request: request, callback: callback, callback_args: callback_args, raise_error_responses: raise_error_responses}
      "req-#{captured.size}"
    }

    PatientHttp.register_handler(fake_handler)
    begin
      yield captured
    ensure
      PatientHttp.unregister_handler
    end
  end

  def http_response(body, callback_args:)
    PatientHttp::Response.new(
      callback_args: callback_args,
      http_method: :post,
      url: "https://api.openai.com/v1/chat/completions",
      status: 200,
      headers: {"content-type" => "application/json"},
      body: JSON.generate(body),
      duration: 1.0,
      request_id: SecureRandom.uuid
    )
  end

  def request_error(callback_args)
    PatientHttp::RequestError.new(
      class_name: "Timeout::Error",
      message: "timed out",
      backtrace: [],
      error_type: :timeout,
      duration: 1.0,
      request_id: "req-1",
      url: "https://api.openai.com/v1/chat/completions",
      http_method: :post,
      callback_args: callback_args
    )
  end

  def text_body(text)
    {"choices" => [{"message" => {"role" => "assistant", "content" => text}}], "model" => "gpt-4"}
  end

  def tool_call_body(name, arguments)
    {
      "choices" => [
        {
          "message" => {
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              {"id" => "call_1", "type" => "function", "function" => {"name" => name, "arguments" => JSON.generate(arguments)}}
            ]
          }
        }
      ],
      "model" => "gpt-4"
    }
  end

  describe "DSL declarations" do
    it "exposes the declared settings" do
      expect(TestTripAgent.provider).to eq(:openai)
      expect(TestTripAgent.model).to eq("gpt-4")
      expect(TestTripAgent.system).to eq("You are a travel assistant.")
      expect(TestTripAgent.instructions).to eq("Answer in one paragraph.")
      expect(TestTripAgent.temperature).to eq(0.3)
      expect(TestTripAgent.max_output_tokens).to eq(500)
      expect(TestTripAgent.max_tool_iterations).to eq(5)
      expect(TestTripAgent.extra).to eq({"guardrail_config" => {"guardrailIdentifier" => "gr-1", "guardrailVersion" => "1"}})
    end

    it "declares tools with schemas from blocks" do
      declaration = TestTripAgent.tools["weather"]
      expect(declaration[:description]).to eq("Get the weather for a city")
      expect(declaration[:parameters]["properties"]["city"]).to eq({"type" => "string", "description" => "City name"})
      expect(declaration[:parameters]["required"]).to eq(["city"])
    end

    it "declares an output schema" do
      expect(TestTripAgent.output_schema[:name]).to eq("response")
      expect(TestTripAgent.output_schema[:schema]["properties"].keys).to contain_exactly("summary", "packing_list")
    end

    it "inherits declarations in subclasses which can override them" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "SpecializedTripAgent"
        end
        model "gpt-4o"
      end

      expect(subclass.model).to eq("gpt-4o")
      expect(subclass.provider).to eq(:openai)
      expect(subclass.system).to eq("You are a travel assistant.")
      expect(subclass.instructions).to eq("Answer in one paragraph.")
      expect(subclass.temperature).to eq(0.3)
      expect(subclass.max_output_tokens).to eq(500)
      expect(subclass.max_tool_iterations).to eq(5)
      expect(subclass.extra).to eq(TestTripAgent.extra)
      expect(subclass.tools.keys).to eq(["weather"])
      expect(subclass.output_schema).to eq(TestTripAgent.output_schema)
      expect(TestTripAgent.model).to eq("gpt-4")
    end

    it "reflects declarations added to the parent after the subclass is defined" do
      parent = Class.new(TestPlainAgent) do
        def self.name
          "LateParentAgent"
        end
      end
      subclass = Class.new(parent) do
        def self.name
          "LateChildAgent"
        end
      end

      parent.temperature 0.9
      parent.tool :lookup, "Look something up" do
        param :key, :string
      end

      expect(subclass.temperature).to eq(0.9)
      expect(subclass.tools.keys).to eq(["lookup"])
    end

    it "removes an inherited setting when passed an explicit nil" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "StrippedTripAgent"
        end
        system nil
        instructions nil
        temperature nil
        max_output_tokens nil
        max_tool_iterations nil
        extra nil
      end

      expect(subclass.system).to be_nil
      expect(subclass.instructions).to be_nil
      expect(subclass.temperature).to be_nil
      expect(subclass.max_output_tokens).to be_nil
      expect(subclass.max_tool_iterations).to be_nil
      expect(subclass.extra).to be_nil
      expect(subclass.model).to eq("gpt-4")

      expect(TestTripAgent.system).to eq("You are a travel assistant.")
      expect(TestTripAgent.temperature).to eq(0.3)
    end

    it "masks a removed setting from further subclasses" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "NoTemperatureTripAgent"
        end
        temperature nil
      end
      grandchild = Class.new(subclass) do
        def self.name
          "GrandchildTripAgent"
        end
      end

      expect(grandchild.temperature).to be_nil
    end

    it "removes inherited reasoning when passed an explicit nil" do
      parent = Class.new(TestPlainAgent) do
        def self.name
          "ReasoningParentAgent"
        end
        reasoning :medium
      end
      subclass = Class.new(parent) do
        def self.name
          "NoReasoningAgent"
        end
        reasoning nil
      end

      expect(parent.reasoning).to eq({effort: "medium"})
      expect(subclass.reasoning).to be_nil
    end

    it "replaces inherited extra when redeclared in a subclass" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "ExtraOverridingTripAgent"
        end
        extra stop_sequences: ["END"]
      end

      expect(subclass.extra).to eq({"stop_sequences" => ["END"]})
      expect(TestTripAgent.extra).to eq({"guardrail_config" => {"guardrailIdentifier" => "gr-1", "guardrailVersion" => "1"}})
    end

    it "raises when extra is not a Hash" do
      expect {
        Class.new(TestPlainAgent) do
          def self.name
            "BadExtraAgent"
          end
          extra "not a hash"
        end
      }.to raise_error(ArgumentError, "extra must be a Hash")
    end

    it "resolves a block declaration each time the value is read" do
      model_name = "gpt-4o"
      agent = Class.new(TestPlainAgent) do
        def self.name
          "BlockValueAgent"
        end
      end
      agent.model { model_name }

      expect(agent.model).to eq("gpt-4o")
      model_name = "gpt-4o-mini"
      expect(agent.model).to eq("gpt-4o-mini")
    end

    it "resolves a callable argument each time the value is read" do
      temperature_value = 0.5
      agent = Class.new(TestPlainAgent) do
        def self.name
          "CallableValueAgent"
        end
      end
      agent.temperature -> { temperature_value }

      expect(agent.temperature).to eq(0.5)
      temperature_value = 0.9
      expect(agent.temperature).to eq(0.9)
    end

    it "coerces a dynamic provider value at read time" do
      agent = Class.new(TestPlainAgent) do
        def self.name
          "DynamicProviderAgent"
        end
        provider -> { "openai" }
      end

      expect(agent.provider).to eq(:openai)
    end

    it "jsonifies a dynamic extra value at read time" do
      agent = Class.new(TestPlainAgent) do
        def self.name
          "DynamicExtraAgent"
        end
        extra { {stop_sequences: ["END"]} }
      end

      expect(agent.extra).to eq({"stop_sequences" => ["END"]})
    end

    it "validates a dynamic extra value at read time rather than when declared" do
      agent = Class.new(TestPlainAgent) do
        def self.name
          "BadDynamicExtraAgent"
        end
        extra { "not a hash" }
      end

      expect { agent.extra }.to raise_error(ArgumentError, "extra must be a Hash")
    end

    it "inherits a block declaration and resolves it live through the subclass" do
      system_message = "Be terse."
      parent = Class.new(TestPlainAgent) do
        def self.name
          "DynamicParentAgent"
        end
      end
      parent.system { system_message }
      subclass = Class.new(parent) do
        def self.name
          "DynamicChildAgent"
        end
      end

      expect(subclass.system).to eq("Be terse.")
      system_message = "Be verbose."
      expect(subclass.system).to eq("Be verbose.")
    end

    it "removes an inherited block declaration when passed an explicit nil" do
      parent = Class.new(TestPlainAgent) do
        def self.name
          "MaskedDynamicParentAgent"
        end
        extra { {stop_sequences: ["END"]} }
      end
      subclass = Class.new(parent) do
        def self.name
          "MaskedDynamicChildAgent"
        end
        extra nil
      end

      expect(subclass.extra).to be_nil
      expect(parent.extra).to eq({"stop_sequences" => ["END"]})
    end

    it "lets a subclass override an inherited plain value with a block" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "DynamicOverridingTripAgent"
        end
        model { "gpt-4o" }
      end

      expect(subclass.model).to eq("gpt-4o")
      expect(TestTripAgent.model).to eq("gpt-4")
    end

    it "raises when both an argument and a block are given" do
      expect {
        TestPlainAgent.model("gpt-4o") { "gpt-4o-mini" }
      }.to raise_error(ArgumentError, "pass either an argument or a block, not both")

      expect {
        TestPlainAgent.extra({stop_sequences: ["END"]}) { {} }
      }.to raise_error(ArgumentError, "pass either an argument or a block, not both")
    end

    it "replaces an inherited tool when redeclared in a subclass" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "OverridingTripAgent"
        end
        tool :weather, "Get a detailed forecast" do
          param :city, :string, required: true
          param :days, :integer
        end
      end

      expect(subclass.tools["weather"][:description]).to eq("Get a detailed forecast")
      expect(subclass.tools["weather"][:parameters]["properties"].keys).to contain_exactly("city", "days")
      expect(TestTripAgent.tools["weather"][:description]).to eq("Get the weather for a city")
    end

    it "returns tool declarations as deep copies so mutating them does not alter the agent's" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "MutatingTripAgent"
        end
      end

      subclass.tools["weather"][:description] = "changed"
      subclass.tools["weather"][:parameters]["properties"]["city"]["description"] = "changed"
      TestTripAgent.tools["weather"][:description] = "changed"

      expect(TestTripAgent.tools["weather"][:description]).to eq("Get the weather for a city")
      expect(TestTripAgent.tools["weather"][:parameters]["properties"]["city"]["description"]).to eq("City name")
    end

    it "raises when a subclass redefines a plumbing method" do
      expect {
        Class.new(PatientLLM::Agent) do
          def on_complete(response)
          end
        end
      }.to raise_error(ArgumentError, /must not redefine on_complete/)
    end
  end

  describe ".build_session" do
    it "applies the agent's declarations to a new session" do
      session = TestTripAgent.build_session

      expect(session.model).to eq("gpt-4")
      system_messages = session.items.select { |item| item.role == "system" }
      expect(system_messages.map { |m| m.content.first.text }).to eq(["You are a travel assistant."])
      expect(session.instructions).to eq("Answer in one paragraph.")
      expect(session.temperature).to eq(0.3)
      expect(session.max_output_tokens).to eq(500)
      expect(session.extra).to eq({"guardrail_config" => {"guardrailIdentifier" => "gr-1", "guardrailVersion" => "1"}})
      expect(session.text.dig("format", "type")).to eq("json_schema")
      expect(session.tool_definitions.map(&:name)).to eq(["weather"])
    end

    it "applies inherited declarations from the parent agent class" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "InheritedSessionAgent"
        end
      end

      session = subclass.build_session

      expect(session.model).to eq("gpt-4")
      system_messages = session.items.select { |item| item.role == "system" }
      expect(system_messages.map { |m| m.content.first.text }).to eq(["You are a travel assistant."])
      expect(session.text.dig("format", "type")).to eq("json_schema")
      expect(session.tool_definitions.map(&:name)).to eq(["weather"])
    end

    it "does not apply settings removed with an explicit nil" do
      subclass = Class.new(TestTripAgent) do
        def self.name
          "RemovedSettingsSessionAgent"
        end
        system nil
        instructions nil
        temperature nil
      end

      session = subclass.build_session

      expect(session.items.select { |item| item.role == "system" }).to be_empty
      expect(session.instructions).to be_nil
      expect(session.temperature).to be_nil
      expect(session.max_output_tokens).to eq(500)
    end

    it "applies reasoning via think" do
      agent = Class.new(TestPlainAgent) do
        def self.name
          "ReasoningAgent"
        end
        reasoning :medium
      end

      session = agent.build_session
      expect(session.reasoning).to eq({"effort" => "medium"})
    end

    it "applies dynamically generated declarations to the session as resolved values" do
      agent = Class.new(TestPlainAgent) do
        def self.name
          "DynamicSessionAgent"
        end
        temperature { 0.7 }
        extra { {stop_sequences: ["END"]} }
      end

      session = agent.build_session

      expect(session.temperature).to eq(0.7)
      expect(session.extra).to eq({"stop_sequences" => ["END"]})
    end

    it "lets per-request session options override the agent's declarations" do
      session = TestTripAgent.build_session(temperature: 0.9, instructions: "Answer in haiku.", extra: {stop_sequences: ["END"]})

      expect(session.temperature).to eq(0.9)
      expect(session.instructions).to eq("Answer in haiku.")
      expect(session.extra).to eq({"stop_sequences" => ["END"]})
      expect(session.max_output_tokens).to eq(500)
    end

    it "lets an explicit nil session option unset a declared value for one request" do
      session = TestTripAgent.build_session(temperature: nil, extra: nil)

      expect(session.temperature).to be_nil
      expect(session.extra).to eq({})
      expect(session.instructions).to eq("Answer in one paragraph.")
    end

    it "uses the caller's system message instead of the agent's when provided" do
      session = TestTripAgent.build_session(system: "Override system.")

      system_messages = session.items.select { |item| item.system? }
      expect(system_messages.map { |m| m.content.first.text }).to eq(["Override system."])
    end
  end

  describe ".ask" do
    it "sends the message through PatientLLM with the agent as the callback" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a weekend in NYC", context: {trip_id: 7})

        args = captured.first[:callback_args]
        expect(args[:callback]).to eq("TestTripAgent")
        expect(args[:custom]).to eq({"context" => {"trip_id" => 7}})
        expect(args[:max_tool_iterations]).to eq(5)
        expect(args[:session]["input"].last["content"].first["text"]).to eq("Plan a weekend in NYC")
      end
    end

    it "forwards a per-request extra session option to the session" do
      with_fake_handler do |captured|
        TestTripAgent.ask("hi", extra: {stop_sequences: ["END"]})

        expect(captured.first[:callback_args][:session]["extra"]).to eq({"stop_sequences" => ["END"]})
      end
    end

    it "serializes dynamically generated declarations as resolved values" do
      agent = Class.new(TestPlainAgent) do
        extra { {stop_sequences: ["END"]} }
      end
      stub_const("DynamicAskAgent", agent)

      with_fake_handler do |captured|
        agent.ask("hi")

        expect(captured.first[:callback_args][:session]["extra"]).to eq({"stop_sequences" => ["END"]})
      end
    end

    it "raises without a provider" do
      agent = Class.new(PatientLLM::Agent) do
        def self.name
          "ProviderlessAgent"
        end
        model "gpt-4"
      end

      expect { agent.ask("hi") }.to raise_error(ArgumentError, /must declare a provider/)
    end

    it "forwards per-request overrides" do
      with_fake_handler do |captured|
        TestTripAgent.ask("hi", timeout: 300, max_tool_iterations: 2)

        expect(captured.first[:request].timeout).to eq(300)
        expect(captured.first[:callback_args][:max_tool_iterations]).to eq(2)
      end
    end
  end

  describe ".continue" do
    it "restores the session, re-applies current configuration, and adds the message" do
      state = PromptBuilder::Session.new(model: "gpt-4").tap { |s| s.user("First message") }.to_h

      with_fake_handler do |captured|
        TestTripAgent.continue(state, "Make it kid-friendly")

        session_hash = captured.first[:callback_args][:session]
        session = PromptBuilder::Session.from_h(session_hash)
        system_messages = session.items.select { |item| item.role == "system" }
        expect(system_messages.map { |m| m.content.first.text }).to eq(["You are a travel assistant."])
        expect(session.tool_definitions.map(&:name)).to eq(["weather"])
        texts = session.items.select { |item| item.role == "user" }
        expect(texts.map { |m| m.content.first.text }).to eq(["First message", "Make it kid-friendly"])
      end
    end

    it "does not duplicate the system message across continue round-trips" do
      state = TestTripAgent.build_session.tap { |s| s.user("First message") }.to_h

      with_fake_handler do |captured|
        TestTripAgent.continue(state, "Second message")
        state = PromptBuilder::Session.from_h(captured.first[:callback_args][:session]).to_h

        TestTripAgent.continue(state, "Third message")

        session = PromptBuilder::Session.from_h(captured.last[:callback_args][:session])
        system_messages = session.items.select { |item| item.is_a?(PromptBuilder::Items::Message) && item.system? }
        expect(system_messages.map { |m| m.content.first.text }).to eq(["You are a travel assistant."])
      end
    end

    it "replaces the persisted system message when the agent's declaration changed" do
      state = TestTripAgent.build_session.to_h
      state["input"][0]["content"][0]["text"] = "An older system prompt."

      with_fake_handler do |captured|
        TestTripAgent.continue(state, "Hello")

        session = PromptBuilder::Session.from_h(captured.first[:callback_args][:session])
        system_messages = session.items.select { |item| item.is_a?(PromptBuilder::Items::Message) && item.system? }
        expect(system_messages.map { |m| m.content.first.text }).to eq(["You are a travel assistant."])
        expect(session.items.first.system?).to be(true)
      end
    end

    it "replaces persisted extra with the agent's current declaration" do
      state = PromptBuilder::Session.new(model: "gpt-4", extra: {"guardrail_config" => {"guardrailIdentifier" => "old", "guardrailVersion" => "1"}}).to_h

      with_fake_handler do |captured|
        TestTripAgent.continue(state, "Hello")

        session = PromptBuilder::Session.from_h(captured.first[:callback_args][:session])
        expect(session.extra).to eq({"guardrail_config" => {"guardrailIdentifier" => "gr-1", "guardrailVersion" => "1"}})
      end
    end

    it "leaves persisted extra alone when the agent declares none" do
      state = PromptBuilder::Session.new(model: "gpt-4", extra: {"stop_sequences" => ["END"]}).to_h

      with_fake_handler do |captured|
        TestPlainAgent.continue(state, "Hello")

        session = PromptBuilder::Session.from_h(captured.first[:callback_args][:session])
        expect(session.extra).to eq({"stop_sequences" => ["END"]})
      end
    end

    it "re-applies the agent's current model to a restored session" do
      state = PromptBuilder::Session.new(model: "gpt-3.5-turbo").tap { |s| s.user("First message") }.to_h

      with_fake_handler do |captured|
        TestTripAgent.continue(state, "Hello")

        session = PromptBuilder::Session.from_h(captured.first[:callback_args][:session])
        expect(session.model).to eq("gpt-4")
      end
    end

    it "leaves the persisted model alone when the agent declares none" do
      agent_class = Class.new(PatientLLM::Agent) do
        provider :openai
      end
      stub_const("ModellessAgent", agent_class)
      state = PromptBuilder::Session.new(model: "gpt-3.5-turbo").to_h

      with_fake_handler do |captured|
        ModellessAgent.continue(state, "Hello")

        session = PromptBuilder::Session.from_h(captured.first[:callback_args][:session])
        expect(session.model).to eq("gpt-3.5-turbo")
      end
    end
  end

  describe "completion handling" do
    it "invokes completed with an Agent::Response exposing text, object, state, context, and the HTTP exchange" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", context: {trip_id: 7})

        body = text_body('{"summary": "NYC weekend", "packing_list": ["socks"]}')
        PatientLLM::Callback.new.on_complete(http_response(body, callback_args: captured.first[:callback_args]))
      end

      response = TestTripAgent.recorded[:completed]
      expect(response).to be_a(PatientLLM::Agent::Response)
      expect(response.object).to eq({"summary" => "NYC weekend", "packing_list" => ["socks"]})
      expect(response.state).to be_a(Hash)
      expect(response.context.to_h).to eq({trip_id: 7})
      expect(response.http_response).to be_a(PatientHttp::Response)
      expect(response.http_request_id).to eq(response.http_response.request_id)
      expect(TestTripAgent.recorded[:completed_context]).to eq({trip_id: 7})
    end

    it "exposes context values on the response with []" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", context: {trip_id: 7})

        body = text_body('{"summary": "NYC weekend"}')
        PatientLLM::Callback.new.on_complete(http_response(body, callback_args: captured.first[:callback_args]))
      end

      response = TestTripAgent.recorded[:completed]
      expect(response[:trip_id]).to eq(7)
      expect(response["trip_id"]).to eq(7)
      expect { response[:missing] }.to raise_error(KeyError)
    end

    it "raises StructuredOutputError from object when the response is not JSON" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip")
        PatientLLM::Callback.new.on_complete(http_response(text_body("not json"), callback_args: captured.first[:callback_args]))
      end

      response = TestTripAgent.recorded[:completed]
      expect { response.object }.to raise_error(PatientLLM::StructuredOutputError) do |error|
        expect(error.text).to eq("not json")
      end
    end

    it "raises StructuredOutputError from object when no output schema is declared" do
      with_fake_handler do |captured|
        TestPlainAgent.ask("hi")
        callback_args = captured.first[:callback_args]

        capture = {}
        Thread.current.thread_variable_set(:patient_llm_agent_capture, capture)
        begin
          PatientLLM::Callback.new.on_complete(http_response(text_body("plain text"), callback_args: callback_args))
        ensure
          Thread.current.thread_variable_set(:patient_llm_agent_capture, nil)
        end

        expect(capture[:response].text).to eq("plain text")
        expect { capture[:response].object }.to raise_error(PatientLLM::StructuredOutputError, /no output schema/)
      end
    end

    it "invokes failed with an Agent::Failure wrapping the error" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip")

        error = PatientHttp::RequestError.new(
          class_name: "Timeout::Error",
          message: "timed out",
          backtrace: [],
          error_type: :timeout,
          duration: 1.0,
          request_id: "req-1",
          url: "https://api.openai.com/v1/chat/completions",
          http_method: :post,
          callback_args: captured.first[:callback_args]
        )
        PatientLLM::Callback.new.on_error(error)
      end

      failure = TestTripAgent.recorded[:failed]
      expect(failure).to be_a(PatientLLM::Agent::Failure)
      expect(failure.error).to be_a(PatientHttp::RequestError)
      expect(failure.error_type).to eq(:timeout)
      expect(failure.message).to eq("timed out")
      expect(failure.state).to be_a(Hash)
    end

    it "exposes the context on the failure and leaves http_response nil for transport errors" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", context: {trip_id: 9})

        error = PatientHttp::RequestError.new(
          class_name: "Timeout::Error",
          message: "timed out",
          backtrace: [],
          error_type: :timeout,
          duration: 1.0,
          request_id: "req-1",
          url: "https://api.openai.com/v1/chat/completions",
          http_method: :post,
          callback_args: captured.first[:callback_args]
        )

        PatientLLM::Callback.new.on_error(error)
      end

      failure = TestTripAgent.recorded[:failed]
      expect(failure.http_response).to be_nil
      expect(failure.http_request_id).to eq("req-1")
      expect(TestTripAgent.recorded[:failed_context]).to eq({trip_id: 9})
      expect(failure[:trip_id]).to eq(9)
      expect(failure["trip_id"]).to eq(9)
      expect { failure[:missing] }.to raise_error(KeyError)
    end
  end

  describe "callback option" do
    it "carries the callback class name in the agent's callback args" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", context: {trip_id: 7}, callback: TestTripCallbacks)

        args = captured.first[:callback_args]
        expect(args[:callback]).to eq("TestTripAgent")
        expect(args[:custom]).to eq({"context" => {"trip_id" => 7}, "callback" => "TestTripCallbacks"})
      end
    end

    it "accepts the callback class name as a string" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", callback: "TestTripCallbacks")

        expect(captured.first[:callback_args][:custom]["callback"]).to eq("TestTripCallbacks")
      end
    end

    it "sends completed to the callback class instead of the agent" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", context: {trip_id: 7}, callback: TestTripCallbacks)

        body = text_body('{"summary": "NYC weekend"}')
        PatientLLM::Callback.new.on_complete(http_response(body, callback_args: captured.first[:callback_args]))
      end

      response = TestTripCallbacks.recorded[:completed]
      expect(response).to be_a(PatientLLM::Agent::Response)
      expect(response.object).to eq({"summary" => "NYC weekend"})
      expect(response.context.to_h).to eq({trip_id: 7})
      expect(TestTripAgent.recorded).to eq({})
    end

    it "sends failed to the callback class instead of the agent" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", context: {trip_id: 9}, callback: TestTripCallbacks)

        PatientLLM::Callback.new.on_error(request_error(captured.first[:callback_args]))
      end

      failure = TestTripCallbacks.recorded[:failed]
      expect(failure).to be_a(PatientLLM::Agent::Failure)
      expect(failure.error_type).to eq(:timeout)
      expect(failure[:trip_id]).to eq(9)
      expect(TestTripAgent.recorded).to eq({})
    end

    it "sends tool_round to the callback class and survives tool iterations" do
      with_fake_handler do |captured|
        TestTripAgent.ask("What's the weather in NYC?", context: {trip_id: 7}, callback: TestTripCallbacks)

        PatientLLM::Callback.new.on_complete(http_response(tool_call_body("weather", {"city" => "NYC"}), callback_args: captured.first[:callback_args]))

        second_args = captured.last[:callback_args]
        expect(second_args[:custom]["callback"]).to eq("TestTripCallbacks")

        PatientLLM::Callback.new.on_complete(http_response(text_body('{"summary": "Cold"}'), callback_args: second_args))
      end

      # The tool itself still runs on the agent; only the hooks are redirected.
      expect(TestTripAgent.recorded[:weather_args]).to eq({city: "NYC", country: nil})
      expect(TestTripAgent.recorded[:tool_rounds]).to be_nil
      expect(TestTripCallbacks.recorded[:tool_rounds]).to eq(1)
      expect(TestTripCallbacks.recorded[:completed].object).to eq({"summary" => "Cold"})
    end

    it "falls back to the agent for hooks the callback class does not implement" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", callback: TestFailureOnlyCallbacks)
        callback_args = captured.first[:callback_args]

        PatientLLM::Callback.new.on_complete(http_response(text_body('{"summary": "NYC"}'), callback_args: callback_args))
        PatientLLM::Callback.new.on_error(request_error(callback_args))
      end

      expect(TestTripAgent.recorded[:completed]).to be_a(PatientLLM::Agent::Response)
      expect(TestTripAgent.recorded[:failed]).to be_nil
      expect(TestFailureOnlyCallbacks.recorded[:failed]).to be_a(PatientLLM::Agent::Failure)
    end

    it "prepares a callback class that is itself an agent so it exposes session and provider" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", callback: TestAgentCallbacks)

        PatientLLM::Callback.new.on_complete(http_response(text_body('{"summary": "NYC"}'), callback_args: captured.first[:callback_args]))
      end

      expect(TestAgentCallbacks.recorded[:completed]).to be_a(PatientLLM::Agent::Response)
      expect(TestAgentCallbacks.recorded[:session]).to be_a(PromptBuilder::Session)
      expect(TestAgentCallbacks.recorded[:provider]).to eq("openai")
      expect(TestTripAgent.recorded).to eq({})
    end

    it "falls back to the agent's hooks when an agent-subclass callback does not override them" do
      failure_only = Class.new(PatientLLM::Agent) do
        class << self
          attr_accessor :recorded
        end

        def failed(failure)
          self.class.recorded[:failed] = failure
        end
      end
      stub_const("TestAgentFailureOnlyCallbacks", failure_only)
      TestAgentFailureOnlyCallbacks.recorded = {}

      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", callback: TestAgentFailureOnlyCallbacks)

        PatientLLM::Callback.new.on_complete(http_response(text_body('{"summary": "NYC"}'), callback_args: captured.first[:callback_args]))
      end

      # The delegate only overrides failed; the inherited no-op hooks must not
      # shadow the agent's own completed hook.
      expect(TestTripAgent.recorded[:completed]).to be_a(PatientLLM::Agent::Response)
      expect(TestAgentFailureOnlyCallbacks.recorded).to eq({})
    end

    it "raises when an agent-subclass callback overrides none of the hooks" do
      stub_const("HooklessAgentCallbacks", Class.new(PatientLLM::Agent))

      with_fake_handler do
        expect {
          TestTripAgent.ask("hi", callback: HooklessAgentCallbacks)
        }.to raise_error(ArgumentError, /must define at least one of completed, failed, tool_round/)
      end
    end

    it "behaves like the default when the agent names itself as the callback" do
      with_fake_handler do |captured|
        TestTripAgent.ask("Plan a trip", callback: TestTripAgent)

        PatientLLM::Callback.new.on_complete(http_response(text_body('{"summary": "NYC"}'), callback_args: captured.first[:callback_args]))
      end

      expect(TestTripAgent.recorded[:completed]).to be_a(PatientLLM::Agent::Response)
    end

    it "forwards the option through continue" do
      state = TestTripAgent.build_session.to_h

      with_fake_handler do |captured|
        TestTripAgent.continue(state, "Make it kid-friendly", callback: TestTripCallbacks)

        expect(captured.first[:callback_args][:custom]["callback"]).to eq("TestTripCallbacks")
      end
    end

    it "runs the callback class hooks during inline execution and still returns the response" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 200, headers: {"content-type" => "application/json"}, body: JSON.generate(text_body('{"summary": "Cold in NYC"}')))

      response = TestTripAgent.ask!("What's the weather?", callback: TestTripCallbacks)

      expect(response.object).to eq({"summary" => "Cold in NYC"})
      expect(TestTripCallbacks.recorded[:completed]).to be(response)
      expect(TestTripAgent.recorded).to eq({})
    end

    it "raises when the callback class cannot be resolved" do
      with_fake_handler do
        expect { TestTripAgent.ask("hi", callback: "NoSuchCallbackClass") }.to raise_error(NameError)
      end
    end

    it "raises when the callback class implements none of the hooks" do
      stub_const("HooklessCallbacks", Class.new)

      with_fake_handler do
        expect {
          TestTripAgent.ask("hi", callback: HooklessCallbacks)
        }.to raise_error(ArgumentError, /must define at least one of completed, failed, tool_round/)
      end
    end

    it "raises when the callback class is anonymous" do
      with_fake_handler do
        expect {
          TestTripAgent.ask("hi", callback: Class.new { def completed(response) = nil })
        }.to raise_error(ArgumentError, /named class/)
      end
    end
  end

  describe "tool execution" do
    it "routes declared tools to agent instance methods, passing context to tools that declare it" do
      with_fake_handler do |captured|
        TestTripAgent.ask("What's the weather in NYC?", context: {trip_id: 7})

        # First response asks for the weather tool; the loop re-dispatches through the fake handler.
        PatientLLM::Callback.new.on_complete(http_response(tool_call_body("weather", {"city" => "NYC"}), callback_args: captured.first[:callback_args]))
        expect(captured.size).to eq(2)

        # The re-dispatched request carries the tool result; complete it with text.
        second_args = captured.last[:callback_args]
        expect(second_args[:tool_iteration]).to eq(1)
        session = PromptBuilder::Session.from_h(second_args[:session])
        outputs = session.items.select { |i| i.is_a?(PromptBuilder::Items::FunctionCallOutput) }
        expect(outputs.first.output).to eq("72F in NYC")

        PatientLLM::Callback.new.on_complete(http_response(text_body('{"summary": "Cold", "packing_list": []}'), callback_args: second_args))
      end

      expect(TestTripAgent.recorded[:weather_args]).to eq({city: "NYC", country: nil})
      expect(TestTripAgent.recorded[:weather_context]).to eq({trip_id: 7})
      expect(TestTripAgent.recorded[:tool_rounds]).to eq(1)
      expect(TestTripAgent.recorded[:tool_round_response].http_response).to be_a(PatientHttp::Response)
      expect(TestTripAgent.recorded[:tool_round_response].context.to_h).to eq({trip_id: 7})
      expect(TestTripAgent.recorded[:completed].object["summary"]).to eq("Cold")
    end

    it "does not handle tools that are not declared" do
      agent = TestTripAgent.new
      expect(agent.handles_tool?("weather")).to be true
      expect(agent.handles_tool?("undeclared")).to be false
    end

    it "raises rather than routing a declared tool to an inherited Object method" do
      agent_class = Class.new(PatientLLM::Agent) do
        def self.name
          "CollidingToolAgent"
        end
        provider :openai
        model "gpt-4"

        tool :freeze, "A tool colliding with Object#freeze"
      end

      expect {
        agent_class.new.handles_tool?("freeze")
      }.to raise_error(NoMethodError, /does not define a public instance method #freeze/)
    end

    it "raises when a declared tool's handler method is private" do
      agent_class = Class.new(PatientLLM::Agent) do
        def self.name
          "PrivateToolAgent"
        end
        provider :openai
        model "gpt-4"

        tool :search, "Search"

        private

        def search(query: nil)
          "results"
        end
      end

      expect {
        agent_class.new.handles_tool?("search")
      }.to raise_error(NoMethodError, /does not define a public instance method #search/)
    end

    it "raises when a declared tool has no handler method at all" do
      agent_class = Class.new(PatientLLM::Agent) do
        def self.name
          "MissingToolAgent"
        end
        provider :openai
        model "gpt-4"

        tool :lookup, "Lookup with a typo'd handler"
      end

      expect {
        agent_class.new.handles_tool?("lookup")
      }.to raise_error(NoMethodError, /does not define a public instance method #lookup/)
    end

    it "handles tools implemented in modules mixed into the agent" do
      helper = Module.new do
        def lookup(id: nil)
          "found #{id}"
        end
      end

      agent_class = Class.new(PatientLLM::Agent) do
        def self.name
          "MixinToolAgent"
        end
        provider :openai
        model "gpt-4"

        tool :lookup, "Lookup" do
          param :id, :string
        end
      end
      agent_class.include(helper)

      agent = agent_class.new
      expect(agent.handles_tool?("lookup")).to be true
      expect(agent.invoke_tool("lookup", {"id" => "42"})).to eq("found 42")
    end

    it "does not pass context to tool methods that do not declare it" do
      agent_class = Class.new(PatientLLM::Agent) do
        def self.name
          "NoContextToolAgent"
        end
        provider :openai
        model "gpt-4"

        tool :ping, "Ping" do
          param :value, :string
        end

        def ping(value: nil)
          "pong #{value}"
        end
      end

      agent = agent_class.new
      expect(agent.invoke_tool("ping", {"value" => "x"})).to eq("pong x")
    end
  end

  describe ".ask!" do
    it "executes the full request and tool loop inline and returns the response" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(
          {status: 200, headers: {"content-type" => "application/json"}, body: JSON.generate(tool_call_body("weather", {"city" => "NYC"}))},
          {status: 200, headers: {"content-type" => "application/json"}, body: JSON.generate(text_body('{"summary": "Cold in NYC", "packing_list": ["coat"]}'))}
        )

      response = TestTripAgent.ask!("What's the weather in NYC?", context: {trip_id: 7})

      expect(response).to be_a(PatientLLM::Agent::Response)
      expect(response.object).to eq({"summary" => "Cold in NYC", "packing_list" => ["coat"]})
      expect(TestTripAgent.recorded[:weather_args]).to eq({city: "NYC", country: nil})
      expect(TestTripAgent.recorded[:completed]).to be_a(PatientLLM::Agent::Response)
    end

    it "raises the error when the request fails" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 500, body: "oops")

      expect {
        TestTripAgent.ask!("hi")
      }.to raise_error(PatientHttp::Error)

      expect(TestTripAgent.recorded[:failed]).to be_a(PatientLLM::Agent::Failure)
      expect(TestTripAgent.recorded[:failed].error).to be_a(PatientHttp::Error)
    end
  end

  describe ".preview_request" do
    it "builds the request from the agent's declarations without sending anything" do
      with_fake_handler do |captured|
        preview = TestTripAgent.preview_request("What's the weather in NYC?")

        expect(captured).to be_empty
        expect(preview).to be_a(PatientLLM::RequestPreview)
        expect(preview.url).to eq("https://api.openai.com/v1/chat/completions")
        expect(preview.payload["model"]).to eq("gpt-4")
        expect(preview.payload["temperature"]).to eq(0.3)
        expect(preview.payload["max_completion_tokens"]).to eq(500)
        expect(JSON.generate(preview.payload)).to include("What's the weather in NYC?")
        expect(JSON.generate(preview.payload)).to include("You are a travel assistant.")
        expect(preview.payload["tools"].first.dig("function", "name")).to eq("weather")
        expect(preview.headers["Authorization"]).to eq("<secret:openai.api_key>")
      end
    end

    it "honors per-request session options" do
      preview = TestTripAgent.preview_request("hi", model: "gpt-4o", temperature: 0.9)

      expect(preview.payload["model"]).to eq("gpt-4o")
      expect(preview.payload["temperature"]).to eq(0.9)
    end

    it "appends the message to a passed session" do
      session = PromptBuilder::Session.new(model: "gpt-4").tap { |s| s.user("First message") }
      preview = TestTripAgent.preview_request("Second message", session: session)

      expect(JSON.generate(preview.payload)).to include("First message")
      expect(JSON.generate(preview.payload)).to include("Second message")
    end

    it "raises when session options are passed with a session" do
      session = PromptBuilder::Session.new(model: "gpt-4")

      expect {
        TestTripAgent.preview_request("hi", session: session, model: "gpt-4o")
      }.to raise_error(ArgumentError, /session options cannot be passed/)
    end

    it "raises without a provider" do
      agent = Class.new(PatientLLM::Agent) do
        def self.name
          "ProviderlessPreviewAgent"
        end
        model "gpt-4"
      end

      expect { agent.preview_request("hi") }.to raise_error(ArgumentError, /must declare a provider/)
    end
  end

  describe "default failed hook" do
    it "re-raises the error so unhandled failures are not silently lost" do
      with_fake_handler do |captured|
        TestPlainAgent.ask("hi")

        error = PatientHttp::RequestError.new(
          class_name: "Timeout::Error",
          message: "timed out",
          backtrace: [],
          error_type: :timeout,
          duration: 1.0,
          request_id: "req-1",
          url: "https://api.openai.com/v1/chat/completions",
          http_method: :post,
          callback_args: captured.first[:callback_args]
        )

        expect {
          PatientLLM::Callback.new.on_error(error)
        }.to raise_error(PatientHttp::RequestError, "timed out")
      end
    end

    it "does not raise on its own during inline capture so ask! surfaces the original error once" do
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 500, body: "oops")

      expect {
        TestPlainAgent.ask!("hi")
      }.to raise_error(PatientHttp::HttpError)
    end
  end
end
