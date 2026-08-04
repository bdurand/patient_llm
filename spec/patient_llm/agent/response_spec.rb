# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientLLM::Agent::Response do
  def build_session(model: "gpt-4")
    session = PromptBuilder::Session.new(model: model, system: "You are a travel assistant.")
    session.user("What should I pack for Paris?")
    session
  end

  def build_response(llm_response, **options)
    session = options.delete(:session)
    unless session
      session = build_session
      session.add_response(llm_response)
    end
    PatientLLM::Agent::Response.new(llm_response, session: session, **options)
  end

  def http_response(body)
    PatientHttp::Response.new(
      status: 200,
      headers: {"content-type" => "application/json"},
      body: JSON.generate(body),
      duration: 1.0,
      request_id: "req-123",
      url: "https://api.openai.com/v1/chat/completions",
      http_method: :post
    )
  end

  def tool_call_response
    PromptBuilder::Response.new(
      status: "completed",
      output: [
        PromptBuilder::Items::FunctionCall.new(name: "weather", call_id: "call_1", arguments: {"city" => "Paris"})
      ]
    )
  end

  describe "#llm_response" do
    it "returns the underlying LLM response" do
      llm_response = PromptBuilder::Response.from_text("Pack an umbrella.")
      response = build_response(llm_response)

      expect(response.llm_response).to be(llm_response)
    end
  end

  describe "#session" do
    it "returns the session" do
      llm_response = PromptBuilder::Response.from_text("Pack an umbrella.")
      session = build_session
      session.add_response(llm_response)
      response = PatientLLM::Agent::Response.new(llm_response, session: session)

      expect(response.session).to be(session)
    end
  end

  describe "#http_response" do
    it "returns the HTTP response that produced the LLM response" do
      http = http_response({"choices" => []})
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."), http_response: http)

      expect(response.http_response).to be(http)
    end

    it "is nil when no HTTP response is given" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.http_response).to be_nil
    end
  end

  describe "#http_request_id" do
    it "returns the request id of the HTTP exchange" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."), http_request_id: "req-123")

      expect(response.http_request_id).to eq("req-123")
    end

    it "is nil when no request id is given" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.http_request_id).to be_nil
    end
  end

  describe "#context" do
    it "returns the context passed to ask/continue" do
      context = PatientHttp::CallbackArgs.new({user_id: 123})
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."), context: context)

      expect(response.context).to be(context)
    end

    it "defaults to an empty CallbackArgs when no context is given" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.context).to be_a(PatientHttp::CallbackArgs)
      expect(response.context.to_h).to eq({})
    end
  end

  describe "#[]" do
    it "returns the context value for a symbol or string key" do
      context = PatientHttp::CallbackArgs.new({user_id: 123})
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."), context: context)

      expect(response[:user_id]).to eq(123)
      expect(response["user_id"]).to eq(123)
    end

    it "raises KeyError when the key is not in the context" do
      context = PatientHttp::CallbackArgs.new({user_id: 123})
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."), context: context)

      expect { response[:missing] }.to raise_error(KeyError)
    end
  end

  describe "#text" do
    it "returns the text of the response" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.text).to eq("Pack an umbrella.")
    end

    it "is nil when the response has no text output" do
      llm_response = tool_call_response
      response = build_response(llm_response)

      expect(response.text).to be_nil
    end
  end

  describe "#object" do
    it "returns the structured output parsed as JSON" do
      llm_response = PromptBuilder::Response.from_text('{"summary": "Pack light.", "packing_list": ["umbrella"]}')
      response = build_response(llm_response, output_schema: {"type" => "object"})

      expect(response.object).to eq({"summary" => "Pack light.", "packing_list" => ["umbrella"]})
    end

    it "memoizes the parsed value" do
      llm_response = PromptBuilder::Response.from_text('{"summary": "Pack light."}')
      response = build_response(llm_response, output_schema: {"type" => "object"})

      expect(response.object).to be(response.object)
    end

    it "raises StructuredOutputError when the agent has no output schema" do
      llm_response = PromptBuilder::Response.from_text('{"summary": "Pack light."}')
      response = build_response(llm_response)

      expect { response.object }.to raise_error(PatientLLM::StructuredOutputError) do |error|
        expect(error.message).to include("no output schema")
        expect(error.text).to eq('{"summary": "Pack light."}')
      end
    end

    it "raises StructuredOutputError when the text is not valid JSON" do
      llm_response = PromptBuilder::Response.from_text("not json")
      response = build_response(llm_response, output_schema: {"type" => "object"})

      expect { response.object }.to raise_error(PatientLLM::StructuredOutputError) do |error|
        expect(error.message).to include("not valid JSON")
        expect(error.text).to eq("not json")
      end
    end
  end

  describe "#state" do
    it "returns the serializable session state" do
      llm_response = PromptBuilder::Response.from_text("Pack an umbrella.")
      session = build_session
      session.add_response(llm_response)
      response = PatientLLM::Agent::Response.new(llm_response, session: session)

      expect(response.state).to eq(session.to_h)
    end
  end

  describe "#usage" do
    it "returns the token usage for the response" do
      usage = PromptBuilder::Usage.new(input_tokens: 10, output_tokens: 5, total_tokens: 15)
      llm_response = PromptBuilder::Response.from_text("Pack an umbrella.", usage: usage)
      response = build_response(llm_response)

      expect(response.usage).to be(usage)
    end

    it "is nil when the response has no usage" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.usage).to be_nil
    end
  end

  describe "#messages" do
    it "returns only the message items in the session" do
      session = build_session
      llm_response = PromptBuilder::Response.new(
        status: "completed",
        output: [
          PromptBuilder::Items::Reasoning.new(id: "rs_1", summary: [{"type" => "summary_text", "text" => "Thinking."}]),
          PromptBuilder::Items::FunctionCall.new(name: "weather", call_id: "call_1", arguments: {"city" => "Paris"}),
          PromptBuilder::Items::Message.new(role: "assistant", content: [PromptBuilder::Content::OutputText.new(text: "Pack an umbrella.")])
        ]
      )
      session.add_response(llm_response)
      response = PatientLLM::Agent::Response.new(llm_response, session: session)

      messages = response.messages
      expect(messages).to all(be_a(PromptBuilder::Items::Message))
      expect(messages.map(&:role)).to eq(["system", "user", "assistant"])
    end
  end

  describe "#model" do
    it "returns the model from the LLM response" do
      llm_response = PromptBuilder::Response.from_text("Pack an umbrella.", model: "gpt-4.1")
      response = build_response(llm_response)

      expect(response.model).to eq("gpt-4.1")
    end

    it "falls back to the session model when the LLM response has no model" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.model).to eq("gpt-4")
    end

    it "is nil when neither the LLM response nor the session has a model" do
      llm_response = PromptBuilder::Response.from_text("Pack an umbrella.")
      session = PromptBuilder::Session.new
      session.user("What should I pack for Paris?")
      session.add_response(llm_response)
      response = PatientLLM::Agent::Response.new(llm_response, session: session)

      expect(response.model).to be_nil
    end
  end

  describe "#has_tool_calls?" do
    it "is true when the response contains tool calls" do
      response = build_response(tool_call_response)

      expect(response.has_tool_calls?).to be(true)
    end

    it "is false when the response contains no tool calls" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.has_tool_calls?).to be(false)
    end
  end

  describe "#tool_calls" do
    it "returns the tool calls in the response" do
      response = build_response(tool_call_response)

      tool_calls = response.tool_calls
      expect(tool_calls.size).to eq(1)
      expect(tool_calls.first).to be_a(PromptBuilder::Items::FunctionCall)
      expect(tool_calls.first.name).to eq("weather")
      expect(tool_calls.first.call_id).to eq("call_1")
    end

    it "is empty when the response contains no tool calls" do
      response = build_response(PromptBuilder::Response.from_text("Pack an umbrella."))

      expect(response.tool_calls).to eq([])
    end
  end
end
