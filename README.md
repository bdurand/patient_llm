# PatientHttp::LLM

:construction: NOT RELEASED :construction:

[![Continuous Integration](https://github.com/bdurand/patient_http-llm/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http-llm/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http-llm.svg)](https://badge.fury.io/rb/patient_http-llm)

Integrate LLM APIs with your Ruby backend applications without blocking threads. This gem uses asynchronous HTTP requests to call LLM providers using the [OpenAI Chat Completions API](https://platform.openai.com/docs/api-reference/chat) format. When a response is returned, your specified callback is invoked to handle the result.

LLM API calls can take a long time to complete. With traditional synchronous HTTP clients, these requests tie up application threads while waiting for responses. This gem solves that problem by using async HTTP via [PatientHttp](https://github.com/bdurand/patient_http), freeing up your threads to do other work while waiting for the LLM provider to respond.

Many LLM providers support the OpenAI API format natively. For providers that use a different API format (Anthropic, Google, etc.), you can use a proxy like [LiteLLM](https://github.com/BerriAI/litellm) to translate requests into the OpenAI format.

## Prerequisites

This gem delegates actual HTTP dispatch to `patient_http`, which requires a registered request handler before any `chat.ask` call will succeed. In a normal app you get this handler by adding one of the job-system integrations:

- [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq)
- [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue)

Without a handler, `chat.ask` raises `RuntimeError: No request handler registered`.

## Usage

### Configuration

Register your LLM providers with their API base URLs and authentication headers:

```ruby
PatientHttp::LLM.configure do |config|
  config.provider :openai,
    url: "https://api.openai.com",
    headers: {"Authorization" => "Bearer #{ENV["OPENAI_API_KEY"]}"}
end
```

> [!NOTE]
> Authentication headers configured on the provider are re-attached to every request at dispatch time and are persisted in the asynchronous job payload.
>
> You should set up encryption for you job payloads to prevent leaking credentials. See the documentation for [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq#sensitive-data-handling) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue#sensitive-data-handling) for details.

### Creating a Callback Class

Create a callback class with `on_complete` and `on_error` methods:

```ruby
class LLMCallback
  def on_complete(chat, message, callback_args, response)
    # chat          - the PatientHttp::LLM::Chat instance
    # message       - a PatientHttp::LLM::Message with the assistant's response
    # callback_args - a PatientHttp::CallbackArgs containing your custom data
    # response      - the raw PatientHttp::Response with timing info

    # Add the response to the conversation for multi-turn chats
    chat.add_message(message)

    # Access the response content
    puts message.content
    puts "Tokens: #{message.input_tokens} in / #{message.output_tokens} out"
    puts "Duration: #{response.duration}s"

    # Save the chat state for future turns
    save_chat_state(callback_args[:user_id], chat.as_json)
  end

  def on_error(chat, callback_args, error)
    # error is a PatientHttp::RequestError, ClientError (HTTP 4xx),
    # or ServerError (HTTP 5xx). All respond to:
    #   error.error_type  - :timeout, :connection, :ssl, :http_error, etc.
    #   error.message     - human-readable message
    #   error.error_class - the original exception class (for RequestError)
    #   error.request_id
    # HTTP errors additionally expose error.response (a PatientHttp::Response).

    log_error(error.error_type, error.message)
  end
end
```

### Making LLM Requests

Create a `Chat` instance and call `ask` to make an async request:

```ruby
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback, model: "gpt-4o", provider: :openai)
chat.with_instructions("You are a helpful assistant.")
chat.ask("What is the capital of France?")
```

You can pass custom data to your callback using `callback_args`:

```ruby
chat.ask("Hello!", callback_args: {
  user_id: current_user.id,
  conversation_id: conversation.id
})
```

The request is sent asynchronously. When the LLM responds, your callback's `on_complete` method will be called with the result.

### Chat Configuration Options

The `Chat` class supports various configuration methods:

```ruby
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback)

# Set the model
chat.with_model("gpt-4o", provider: :openai)

# Set temperature
chat.with_temperature(0.7)

# Enable reasoning for supported models (OpenAI o1/o3 family)
chat.with_thinking(effort: "high")

# Set a JSON schema for structured output
chat.with_schema({
  type: "object",
  properties: {
    answer: { type: "string" },
    confidence: { type: "number" }
  }
})

# Add provider-specific parameters (deep-merged into the final payload)
chat.with_params(max_completion_tokens: 1000)

# Add custom HTTP headers
# NOTE: do NOT put secrets here — chat state is serialized into the job queue.
# Use the provider registry for Authorization tokens instead.
chat.with_headers("X-Custom-Header" => "value")

# Use a custom API base URL (for LM Studio, Ollama, etc.)
chat.with_api_base("http://localhost:1234")

# Register tools for function calling (see "Tool calling" below)
chat.with_tools([WeatherTool, TimeTool])
```

### URL composition

The full request URL is built by concatenating the `api_base` (from the chat or provider registry) with the chat's `completion_path` (default `/v1/chat/completions`). Trailing slashes on the base and leading slashes on the path are normalized, so:

```
api_base = "https://api.openai.com"            completion_path = "/v1/chat/completions"
-> https://api.openai.com/v1/chat/completions

api_base = "http://localhost:1234"             completion_path = "/v1/chat/completions"
-> http://localhost:1234/v1/chat/completions
```

If your base URL already includes a `/v1` prefix, override the completion path to avoid duplication:

```ruby
chat.with_api_base("https://my-gateway.internal/openai/v1")
chat.instance_variable_set(:@completion_path, "/chat/completions")
# ... or use Chat.new(completion_path: "/chat/completions", ...)
```

### Tool calling

Subclass `PatientHttp::LLM::Tool` to define tools:

```ruby
class WeatherTool < PatientHttp::LLM::Tool
  description "Get the current weather for a location"
  param :location, type: "string", desc: "City name"

  def execute(location:)
    WeatherService.lookup(location)  # returns a String or JSON-serializable object
  end
end
```

Register tools on the chat and ask normally:

```ruby
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback, model: "gpt-4o", provider: :openai)
chat.with_tools([WeatherTool])
chat.ask("What's the weather in NYC?")
```

When the model responds with tool calls, the gem automatically:

1. Appends the assistant tool-call message to the chat.
2. Invokes each matching tool's `#execute` with the LLM-provided arguments.
3. Appends a tool-response message for each tool call.
4. Re-issues the chat request asynchronously.
5. Repeats until the model returns a plain text response (or a tool returns `halt`). Your `on_complete` callback only fires for the final text response.

The loop is capped at `PatientHttp::LLM::Callback::MAX_TOOL_ITERATIONS` (10) iterations per conversation to prevent runaway calls. Exceeding the cap raises inside the callback and surfaces via your error handler.

**Tool classes must be autoloadable** at the time the callback fires, since chat state is persisted across async turns by storing class names.

#### Halting the loop

Return `halt(...)` from a tool's `execute` method to stop the auto-loop and surface the halt content as the final assistant message:

```ruby
class AuthTool < PatientHttp::LLM::Tool
  description "Authenticates the user"
  param :token, type: "string", desc: "Auth token"

  def execute(token:)
    return halt("Authentication failed.") unless AuthService.valid?(token)
    AuthService.session_info(token)
  end
end
```

### Serializing Conversations

Conversations can be serialized to JSON for storage and later restored:

```ruby
# Initial request
chat = PatientHttp::LLM::Chat.new(callback: LLMCallback, model: "gpt-4o", provider: :openai)
chat.with_instructions("You are a helpful assistant.")
chat.ask("Hello!", callback_args: { conversation_id: conversation.id })

# In your callback, save the state:
def on_complete(chat, message, callback_args, response)
  chat.add_message(message)
  save_to_database(callback_args[:conversation_id], chat.as_json)
end

# Later, restore and continue:
chat_data = load_from_database(conversation_id)
chat = PatientHttp::LLM::Chat.load(chat_data)
chat.ask("Tell me more about that.", callback_args: { conversation_id: conversation_id })
```

Serialized chats include messages, tool-call history, provider/model settings, and registered tool class names. They do **not** include provider-level Authorization headers.

## Installation

This gem is not yet published to RubyGems. Add it from GitHub:

```ruby
gem "patient_http-llm", github: "bdurand/patient_http-llm"
```

Then execute:
```bash
$ bundle
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http-llm).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
