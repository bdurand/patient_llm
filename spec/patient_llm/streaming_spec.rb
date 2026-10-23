# frozen_string_literal: true

require "spec_helper"
require "zlib"

class TestStreamCallback
  class << self
    attr_accessor :recorded
  end

  def on_complete(session:, llm_response:, http_response:)
    self.class.recorded[:session] = session
    self.class.recorded[:llm_response] = llm_response
    self.class.recorded[:http_response] = http_response
  end

  def on_error(error:, http_response:)
    self.class.recorded[:error] = error
    self.class.recorded[:http_response] = http_response
  end
end

class TestStreamingAgent < PatientLLM::Agent
  provider :stream_messages
  model "claude-sonnet-4-5"
  max_output_tokens 1000
  stream true

  tool :weather, "Get the weather for a city" do
    param :city, :string, "City name", required: true
  end

  class << self
    attr_accessor :recorded
  end

  def weather(city:)
    "72F in #{city}"
  end

  def completed(response)
    self.class.recorded[:completed] = response
  end

  def failed(failure)
    self.class.recorded[:failed] = failure
  end
end

RSpec.describe PatientLLM, "streaming" do
  let(:messages_url) { "https://api.anthropic.example/v1/messages" }

  let(:session) do
    PromptBuilder::Session.new(model: "claude-sonnet-4-5", max_output_tokens: 1000).tap { |s| s.user("Hello") }
  end

  before do
    TestStreamCallback.recorded = {}
    TestStreamingAgent.recorded = {}

    PatientLLM.configure do |c|
      c.provider :stream_messages, url: "https://api.anthropic.example", serializer: :messages
      c.provider :stream_gemini, url: "https://gemini.example", serializer: :gemini
      c.provider :stream_converse, url: "https://bedrock.example", serializer: :converse
      c.provider :stream_default, url: "https://api.anthropic.example", serializer: :messages,
        stream: true, read_timeout: 30, max_response_size: 4_000_000
    end
  end

  def with_fake_handler
    captured = nil
    fake_handler = ->(request:, callback:, callback_args:, raise_error_responses:) {
      captured = {request: request, callback_args: callback_args}
      "req-id"
    }

    PatientHttp.register_handler(fake_handler)
    begin
      yield -> { captured }
    ensure
      PatientHttp.unregister_handler
    end
  end

  def payload(captured)
    JSON.parse(captured.call[:request].body)
  end

  def sse(*events)
    events.map { |event| "event: #{event["type"]}\ndata: #{JSON.generate(event)}\n\n" }.join
  end

  def message_start
    {"type" => "message_start", "message" => {"id" => "msg_1", "type" => "message", "role" => "assistant", "content" => [], "model" => "claude-sonnet-4-5", "stop_reason" => nil, "usage" => {"input_tokens" => 10, "output_tokens" => 1}}}
  end

  def message_end(stop_reason = "end_turn")
    [
      {"type" => "message_delta", "delta" => {"stop_reason" => stop_reason}, "usage" => {"output_tokens" => 12}},
      {"type" => "message_stop"}
    ]
  end

  def text_stream(text)
    sse(
      message_start,
      {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "text", "text" => ""}},
      {"type" => "ping"},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "text_delta", "text" => text[0, 5]}},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "text_delta", "text" => text[5..]}},
      {"type" => "content_block_stop", "index" => 0},
      *message_end
    )
  end

  def tool_use_stream(name, input)
    json = JSON.generate(input)
    sse(
      message_start,
      {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "tool_use", "id" => "toolu_1", "name" => name, "input" => {}}},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "input_json_delta", "partial_json" => json[0, 4]}},
      {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "input_json_delta", "partial_json" => json[4..]}},
      {"type" => "content_block_stop", "index" => 0},
      *message_end("tool_use")
    )
  end

  def sse_response(body)
    {status: 200, headers: {"content-type" => "text/event-stream; charset=utf-8"}, body: body}
  end

  # Encode a Converse stream event as an AWS event-stream message.
  def converse_event(type, payload)
    headers = {":event-type" => type, ":content-type" => "application/json", ":message-type" => "event"}
    header_bytes = headers.map do |name, value|
      [name.bytesize].pack("C") + name.b + [7, value.bytesize].pack("Cn") + value.b
    end.join.b
    payload = JSON.generate(payload).b
    prelude = [12 + header_bytes.bytesize + payload.bytesize + 4, header_bytes.bytesize].pack("NN")
    prelude += [Zlib.crc32(prelude)].pack("N")
    message = prelude + header_bytes + payload
    message + [Zlib.crc32(message)].pack("N")
  end

  describe "request resolution" do
    it "does not stream by default" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback", read_timeout: 30)

        request = captured.call[:request]
        expect(JSON.parse(request.body)).not_to have_key("stream")
        expect(request.read_timeout).to be_nil
        expect(captured.call[:callback_args][:stream]).to eq(false)
      end
    end

    it "sets stream in the payload and records it in the callback args" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback", stream: true)

        expect(captured.call[:request].url).to eq(messages_url)
        expect(payload(captured)["stream"]).to eq(true)
        expect(captured.call[:callback_args][:stream]).to eq(true)
      end
    end

    it "passes the read timeout and max response size to a streamed request" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback",
          stream: true, timeout: 1800, read_timeout: 45, max_response_size: 8_000_000)

        request = captured.call[:request]
        expect(request.timeout).to eq(1800)
        expect(request.read_timeout).to eq(45)
        expect(request.max_response_size).to eq(8_000_000)
      end
    end

    it "passes the max response size to a request that is not streamed" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback", max_response_size: 2_000_000)

        expect(captured.call[:request].max_response_size).to eq(2_000_000)
      end
    end

    it "uses the provider's streaming settings" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_default, callback: "TestStreamCallback")

        request = captured.call[:request]
        expect(JSON.parse(request.body)["stream"]).to eq(true)
        expect(request.read_timeout).to eq(30)
        expect(request.max_response_size).to eq(4_000_000)
      end
    end

    it "lets a request turn off the provider's streaming" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_default, callback: "TestStreamCallback", stream: false)

        request = captured.call[:request]
        expect(JSON.parse(request.body)).not_to have_key("stream")
        expect(request.read_timeout).to be_nil
        expect(captured.call[:callback_args][:stream]).to eq(false)
      end
    end

    it "falls back to the session's stream field" do
      session.stream = true

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback")

        expect(payload(captured)["stream"]).to eq(true)
        expect(captured.call[:callback_args][:stream]).to eq(true)
      end
    end

    it "sends stream false when a request turns off the session's streaming" do
      session.stream = true

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback", stream: false)

        expect(payload(captured)["stream"]).to eq(false)
      end
    end

    it "does not save the request's stream setting in the session" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback", stream: true)

        expect(session.stream).to be_nil
        expect(captured.call[:callback_args][:session]).not_to have_key("stream")
      end
    end

    it "does not modify the caller's session to set the stream field" do
      # A frozen session raises on any write, so this fails if the stream
      # setting is applied to the shared session instead of a copy.
      session.freeze

      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback", stream: true)

        expect(payload(captured)["stream"]).to eq(true)
      end
    end

    it "uses the streaming endpoint for Gemini" do
      gemini_session = PromptBuilder::Session.new(model: "gemini-2.5-flash").tap { |s| s.user("Hi") }

      with_fake_handler do |captured|
        PatientLLM.ask(gemini_session, provider: :stream_gemini, callback: "TestStreamCallback", stream: true)

        expect(captured.call[:request].url).to eq("https://gemini.example/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse")
      end
    end

    it "uses the streaming endpoint for Bedrock Converse" do
      converse_session = PromptBuilder::Session.new(model: "anthropic.claude-sonnet-4-5").tap { |s| s.user("Hi") }

      with_fake_handler do |captured|
        PatientLLM.ask(converse_session, provider: :stream_converse, callback: "TestStreamCallback", stream: true)

        expect(captured.call[:request].url).to eq("https://bedrock.example/model/anthropic.claude-sonnet-4-5/converse-stream")
      end
    end

    it "uses an explicit path as is" do
      gemini_session = PromptBuilder::Session.new(model: "gemini-2.5-flash").tap { |s| s.user("Hi") }

      with_fake_handler do |captured|
        PatientLLM.ask(gemini_session, provider: :stream_gemini, callback: "TestStreamCallback", stream: true, path: "custom/{model}")

        expect(captured.call[:request].url).to eq("https://gemini.example/custom/gemini-2.5-flash")
      end
    end

    it "keeps the stream option across tool-loop iterations" do
      with_fake_handler do |captured|
        PatientLLM.ask(session, provider: :stream_messages, callback: "TestStreamCallback", stream: true)

        expect(captured.call[:callback_args][:request_options]["stream"]).to eq(true)
      end
    end

    it "reflects streaming in the preview" do
      converse_session = PromptBuilder::Session.new(model: "anthropic.claude-sonnet-4-5").tap { |s| s.user("Hi") }
      preview = PatientLLM.preview_request(converse_session, provider: :stream_converse, stream: true)

      expect(preview.url).to eq("https://bedrock.example/model/anthropic.claude-sonnet-4-5/converse-stream")
      expect(session.stream).to be_nil
    end
  end

  describe "response handling" do
    def ask_inline(**options)
      PatientLLM.inline do
        PatientLLM.ask(session, provider: :stream_messages, callback: TestStreamCallback, **options)
      end
    end

    it "reassembles a streamed response" do
      stub_request(:post, messages_url).to_return(sse_response(text_stream("Hello there!")))

      ask_inline(stream: true)

      llm_response = TestStreamCallback.recorded[:llm_response]
      expect(llm_response.text).to eq("Hello there!")
      expect(llm_response.usage.output_tokens).to eq(12)
      expect(WebMock).to have_requested(:post, messages_url).with { |req| JSON.parse(req.body)["stream"] == true }
    end

    it "parses a stream by its content type when streaming was requested another way" do
      stub_request(:post, messages_url).to_return(sse_response(text_stream("From params")))

      ask_inline(params: {stream: true})

      expect(TestStreamCallback.recorded[:llm_response].text).to eq("From params")
    end

    it "parses a JSON body returned to a streamed request" do
      body = {"id" => "msg_1", "type" => "message", "role" => "assistant", "model" => "claude-sonnet-4-5",
              "content" => [{"type" => "text", "text" => "Plain JSON"}], "stop_reason" => "end_turn",
              "usage" => {"input_tokens" => 1, "output_tokens" => 2}}
      stub_request(:post, messages_url).to_return(status: 200, headers: {"content-type" => "application/json"}, body: JSON.generate(body))

      ask_inline(stream: true)

      expect(TestStreamCallback.recorded[:llm_response].text).to eq("Plain JSON")
    end

    it "routes an in-stream error event to on_error" do
      body = sse(message_start, {"type" => "error", "error" => {"type" => "overloaded_error", "message" => "Overloaded"}})
      stub_request(:post, messages_url).to_return(sse_response(body))

      ask_inline(stream: true)

      error = TestStreamCallback.recorded[:error]
      expect(error).to be_a(PatientHttp::RequestError)
      expect(error.error_type).to eq(:stream_error)
      expect(error.error_class).to eq(PromptBuilder::ErrorResponseError)
      expect(error.message).to include("Overloaded")
      expect(TestStreamCallback.recorded[:http_response]).to be_a(PatientHttp::Response)
      expect(TestStreamCallback.recorded).not_to have_key(:llm_response)
    end

    it "routes a truncated stream to on_error" do
      body = sse(
        message_start,
        {"type" => "content_block_start", "index" => 0, "content_block" => {"type" => "text", "text" => ""}},
        {"type" => "content_block_delta", "index" => 0, "delta" => {"type" => "text_delta", "text" => "Partial"}}
      )
      stub_request(:post, messages_url).to_return(sse_response(body))

      ask_inline(stream: true)

      error = TestStreamCallback.recorded[:error]
      expect(error.error_type).to eq(:stream_error)
      expect(error.error_class).to eq(PromptBuilder::IncompleteStreamError)
    end

    it "routes a streamed response with no body to on_error" do
      stub_request(:post, messages_url).to_return(status: 204, headers: {"content-type" => "text/event-stream"})

      ask_inline(stream: true)

      error = TestStreamCallback.recorded[:error]
      expect(error.error_type).to eq(:stream_error)
      expect(error.error_class).to eq(PromptBuilder::IncompleteStreamError)
    end

    it "reassembles a streamed Gemini response" do
      gemini_url = "https://gemini.example/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
      chunks = [
        {"candidates" => [{"content" => {"parts" => [{"text" => "Hello"}], "role" => "model"}, "index" => 0}], "modelVersion" => "gemini-2.5-flash"},
        {"candidates" => [{"content" => {"parts" => [{"text" => " world"}], "role" => "model"}, "index" => 0, "finishReason" => "STOP"}],
         "usageMetadata" => {"promptTokenCount" => 3, "candidatesTokenCount" => 2, "totalTokenCount" => 5}, "modelVersion" => "gemini-2.5-flash"}
      ]
      body = chunks.map { |chunk| "data: #{JSON.generate(chunk)}\n\n" }.join
      stub_request(:post, gemini_url).to_return(sse_response(body))
      gemini_session = PromptBuilder::Session.new(model: "gemini-2.5-flash").tap { |s| s.user("Hi") }

      PatientLLM.inline do
        PatientLLM.ask(gemini_session, provider: :stream_gemini, callback: TestStreamCallback, stream: true)
      end

      expect(TestStreamCallback.recorded[:llm_response].text).to eq("Hello world")
    end

    it "reassembles a streamed Bedrock Converse response" do
      converse_url = "https://bedrock.example/model/anthropic.claude-sonnet-4-5/converse-stream"
      body = [
        converse_event("messageStart", {"role" => "assistant"}),
        converse_event("contentBlockDelta", {"contentBlockIndex" => 0, "delta" => {"text" => "Bonjour "}}),
        converse_event("contentBlockDelta", {"contentBlockIndex" => 0, "delta" => {"text" => "☕"}}),
        converse_event("contentBlockStop", {"contentBlockIndex" => 0}),
        converse_event("messageStop", {"stopReason" => "end_turn"}),
        converse_event("metadata", {"usage" => {"inputTokens" => 5, "outputTokens" => 3, "totalTokens" => 8}, "metrics" => {"latencyMs" => 100}})
      ].join
      stub_request(:post, converse_url).to_return(
        status: 200,
        headers: {"content-type" => "application/vnd.amazon.eventstream", "x-amzn-requestid" => "req-123"},
        body: body
      )
      converse_session = PromptBuilder::Session.new(model: "anthropic.claude-sonnet-4-5").tap { |s| s.user("Hi") }

      PatientLLM.inline do
        PatientLLM.ask(converse_session, provider: :stream_converse, callback: TestStreamCallback, stream: true)
      end

      llm_response = TestStreamCallback.recorded[:llm_response]
      expect(llm_response.text).to eq("Bonjour ☕")
      expect(llm_response.usage.output_tokens).to eq(3)
    end
  end

  describe "agents" do
    it "streams requests for an agent that declares stream" do
      with_fake_handler do |captured|
        TestStreamingAgent.ask("Hi")

        expect(payload(captured)["stream"]).to eq(true)
        expect(captured.call[:callback_args][:session]).not_to have_key("stream")
      end
    end

    it "lets the stream option override the declaration" do
      with_fake_handler do |captured|
        TestStreamingAgent.ask("Hi", stream: false)

        expect(payload(captured)).not_to have_key("stream")
      end
    end

    it "accepts the stream option when continuing a conversation" do
      state = PromptBuilder::Session.new(model: "claude-sonnet-4-5").tap { |s| s.user("Hi") }.to_h

      with_fake_handler do |captured|
        TestStreamingAgent.continue(state, "And then?", stream: false)

        expect(payload(captured)).not_to have_key("stream")
      end
    end

    it "reflects the declaration in the preview" do
      preview = TestStreamingAgent.preview_request("Hi")

      expect(preview.payload["stream"]).to eq(true)
    end

    it "runs the tool loop over streamed responses" do
      stub_request(:post, messages_url).to_return(
        sse_response(tool_use_stream("weather", {"city" => "Paris"})),
        sse_response(text_stream("It is 72F in Paris."))
      )

      response = TestStreamingAgent.ask!("Weather in Paris?")

      expect(response.text).to eq("It is 72F in Paris.")
      expect(WebMock).to have_requested(:post, messages_url).twice
      expect(WebMock).to have_requested(:post, messages_url).with { |req|
        body = JSON.parse(req.body)
        body["stream"] == true && body["messages"].any? { |message|
          Array(message["content"]).any? { |block| block.is_a?(Hash) && block["type"] == "tool_result" && block["content"].to_s.include?("72F in Paris") }
        }
      }
    end

    it "sends a stream failure to the failed hook" do
      body = sse(message_start, {"type" => "error", "error" => {"type" => "overloaded_error", "message" => "Overloaded"}})
      stub_request(:post, messages_url).to_return(sse_response(body))

      expect {
        TestStreamingAgent.ask!("Hi")
      }.to raise_error(PatientHttp::RequestError, /Overloaded/)

      failure = TestStreamingAgent.recorded[:failed]
      expect(failure.error_type).to eq(:stream_error)
      expect(failure.http_response).to be_a(PatientHttp::Response)
    end
  end
end
