# PatientLLM

[![Continuous Integration](https://github.com/bdurand/patient_llm/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_llm/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_llm.svg)](https://badge.fury.io/rb/patient_llm)

Integrate LLM APIs with your Ruby backend applications without blocking threads. This gem uses asynchronous HTTP requests to call LLM providers and handles the response via callbacks. It supports multiple API formats natively via [PromptBuilder](https://github.com/bdurand/prompt_builder) serializers:

- **OpenAI Chat Completions** (`:chat_completion`) -- for OpenAI and compatible providers
- **OpenAI Responses** (`:open_responses`) -- for the newer OpenAI Responses API
- **Anthropic Messages** (`:messages`) -- for the Anthropic Claude API
- **Bedrock Converse** (`:converse`) -- for AWS Bedrock Converse API
- **Gemini** (`:gemini`) -- for the Google Gemini API

LLM API calls can take a long time to complete. With traditional synchronous HTTP clients, these requests tie up application threads while waiting for responses. This gem solves that problem by using async HTTP via [PatientHttp](https://github.com/bdurand/patient_http), freeing up your threads to do other work while waiting for the LLM provider to respond.

## Prerequisites

This gem delegates actual HTTP dispatch to `patient_http`, which requires a registered request handler before any `PatientLLM.ask` call will succeed. In a normal app you get this handler by adding one of the job-system integrations:

- [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq)
- [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue)

Without a handler, `PatientLLM.ask` raises `RuntimeError: No request handler registered`.

## Usage

### Configuration

Register your LLM providers with their API base URLs and authentication headers. Authentication headers must be registered using the PatientHttp secrets manager. This ensures that these values are never included in the serialized payloads in the job queue, and are only attached to the request at dispatch time.

```ruby
PatientLLM.configure do |config|
  config.provider :openai,
    url: "https://api.openai.com",
    headers: {"authorization" => PatientHttp.secret("openai.bearer_token")}

  config.provider :anthropic,
    url: "https://api.anthropic.com",
    headers: {"x-api-key" => PatientHttp.secret("anthropic.api_key")},
    serializer: :messages
end

# Register the API keys as secrets with the PatientHttp secrets manager. This example
# is for the Sidekiq integration, but the pattern is the same for SolidQueue.
PatientHttp::Sidekiq.configure do |config|
  config.register_secret("openai.bearer_token") { "Bearer #{ENV.fetch("OPENAI_API_KEY")}" }
  config.register_secret("anthropic.api_key") { ENV.fetch("ANTHROPIC_API_KEY") }
end
```

> [!NOTE]
> You can also set up encryption for your job payloads to ensure the entire serialized payload is always encrypted in the job queue. See the documentation for [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq#sensitive-data-handling) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue#sensitive-data-handling) for details.

### Request signing (preprocessors)

Some providers require request signing rather than a static authentication header — for example, AWS Bedrock with SigV4, where a signature is computed over the final outgoing request. For these, register a [request preprocessor](https://github.com/bdurand/patient_http#request-preprocessors) on the PatientHttp configuration and reference it by name from the provider. Like secrets, only the preprocessor name is serialized into the job queue; the signing logic and credentials stay on the processor side.

```ruby
PatientLLM.configure do |config|
  config.provider :bedrock,
    url: "https://bedrock-runtime.us-east-1.amazonaws.com",
    serializer: :converse,
    preprocessors: :aws_sigv4
end

PatientHttp::Sidekiq.configure do |config|
  config.register_preprocessor(:aws_sigv4) do |request|
    signer = Aws::Sigv4::Signer.new(
      service: "bedrock",
      region: "us-east-1",
      credentials_provider: Aws::CredentialProviderChain.new.resolve
    )
    signature = signer.sign_request(
      http_method: request.http_method.to_s.upcase,
      url: request.url,
      headers: request.headers.to_h,
      body: request.body.to_s
    )
    signature.headers.each { |name, value| request.headers[name] = value }
  end
end
```

Multiple preprocessors can be given as an array; they run in order at dispatch time.

### Creating a Callback Class

Create a callback class with `on_complete` and `on_error` methods. Callbacks receive
**keyword arguments**, and you only declare the ones you need — the dispatcher inspects your
method signature and passes just those values (or everything if you declare `**kwargs`):

```ruby
class LLMCallback
  def on_complete(session:, provider:, llm_response:, callback_args:, http_response:, request_id:)
    # session       - the PromptBuilder::Session with the response already added
    # provider      - the provider name (String)
    # llm_response  - a PromptBuilder::Response with the assistant's response
    # callback_args - a PatientHttp::CallbackArgs containing data you passed in the `ask` call
    # http_response - the raw PatientHttp::Response
    # request_id    - the original request id (stable across tool-call iterations)

    # Access the response content
    puts llm_response.text
    puts "Tokens: #{llm_response.usage.input_tokens} in / #{llm_response.usage.output_tokens} out"
    puts "Duration: #{http_response.duration}s"

    # Save the session state for future turns (response is already in the session)
    save_session_state(callback_args[:user_id], session.to_h)
  end

  def on_error(session:, provider:, callback_args:, error:, http_response:, request_id:)
    # error is a PatientHttp::RequestError, ClientError (HTTP 4xx),
    # or ServerError (HTTP 5xx). All respond to:
    #   error.error_type  - :timeout, :connection, :ssl, :http_error, etc.
    #   error.message     - human-readable message
    #   error.error_class - the original exception class (for RequestError)
    #   error.request_id
    # http_response is the raw PatientHttp::Response for HTTP errors, or nil for
    # transport errors (timeouts, connection failures).

    log_error(error.error_type, error.message)
  end
end
```

#### Callback keyword parameters

Each callback may declare any subset of the keywords below, in any order. Declaring
`**kwargs` receives them all. `PatientLLM.ask` validates your callback's signatures up
front and raises an `ArgumentError` if a method uses an unsupported name, a positional
parameter, or omits the required keyword.

| Callback              | Supported keywords                                                          | Required       |
|-----------------------|-----------------------------------------------------------------------------|----------------|
| `on_complete`         | `session`, `provider`, `llm_response`, `callback_args`, `http_response`, `request_id` | `llm_response` |
| `on_tool_use` (optional) | `session`, `provider`, `llm_response`, `callback_args`, `http_response`, `request_id` | `llm_response` |
| `on_error`            | `session`, `provider`, `callback_args`, `error`, `http_response`, `request_id`        | `error`        |

For example, a callback that only cares about the response text can be as small as:

```ruby
class LLMCallback
  def on_complete(llm_response:)
    puts llm_response.text
  end

  def on_error(error:)
    log_error(error.error_type, error.message)
  end
end
```

### Making LLM Requests

Create a `PromptBuilder::Session` and call `PatientLLM.ask` to make an async request:

```ruby
session = PromptBuilder::Session.new(model: "gpt-4o")
session.instructions = "You are a helpful assistant."
session.user("What is the capital of France?")

PatientLLM.ask(session, provider: :openai, callback: LLMCallback)
```

You can pass custom data to your callback using `callback_args`:

```ruby
PatientLLM.ask(session, provider: :openai, callback: LLMCallback, callback_args: {
  user_id: current_user.id,
  conversation_id: conversation.id
})
```

The request is sent asynchronously. When the LLM responds, your callback's `on_complete` method will be called with the result.

### Session Configuration Options

`PromptBuilder::Session` supports various configuration:

```ruby
session = PromptBuilder::Session.new(model: "gpt-5.4")

# Set system instructions
session.instructions = "You are a helpful assistant."

# Set temperature
session.temperature = 0.7

# Enable reasoning for supported models (OpenAI o1/o3 family)
session.reasoning = {effort: "high"}

# Set a JSON schema for structured output
session.text = {
  format: {
    type: "json_schema",
    json_schema: {
      name: "response",
      schema: {
        type: "object",
        properties: {
          answer: { type: "string" },
          confidence: { type: "number" }
        }
      }
    }
  }
}

# Set the maximum output tokens
session.max_output_tokens = 1000
```

`PatientLLM.ask` accepts additional options:

```ruby
PatientLLM.ask(session,
  provider: :openai,
  callback: LLMCallback,
  url: "http://localhost:1234",            # Override the provider's base URL
  serializer: :messages,                   # Override the API format
  path: "/chat/completions",               # Override the endpoint path
  headers: {"X-Custom" => "value"},        # Additional HTTP headers
  params: {max_completion_tokens: 1000},   # Additional request parameters
  preprocessors: :aws_sigv4                # Replace the provider's request preprocessors
)
```

Note that `headers` and `params` are merged on top of the provider's configured values, while `preprocessors` (like `url`, `serializer`, and `path`) replaces the provider default. Pass `preprocessors: []` to clear a provider-level preprocessor for a single request.

### URL composition

The full request URL is built by concatenating the base URL (from the provider registry or the `url:` option) with the `path`. When you don't set `path`, it defaults to the path for the active serializer (`/v1/chat/completions` for `:chat_completion`, `/v1/responses` for `:open_responses`, `/v1/messages` for `:messages`, `/converse` for `:converse`, `/v1beta/models/{model}:generateContent` for `:gemini`). A `{model}` placeholder in the path is replaced with the session's model at dispatch time, which is how the Gemini default targets Google's `/v1beta/models/{model}:generateContent` endpoint. Trailing slashes on the base and leading slashes on the path are normalized, so:

```
url = "https://api.openai.com"            path = "/v1/chat/completions"
-> https://api.openai.com/v1/chat/completions

url = "http://localhost:1234"             path = "/v1/chat/completions"
-> http://localhost:1234/v1/chat/completions
```

If your base URL already includes a `/v1` prefix, override the path to avoid duplication:

```ruby
PatientLLM.ask(session,
  provider: :openai,
  callback: LLMCallback,
  url: "https://my-gateway.internal/openai/v1",
  path: "chat/completions"
)
```

### Tool calling

Register tools on the global `PromptBuilder.tool_registry`:

```ruby
PromptBuilder.tool_registry.register(
  "weather",
  description: "Get the current weather for a location",
  parameters: {
    type: "object",
    properties: {
      location: {type: "string", description: "City name"}
    },
    required: ["location"]
  }
) do |args|
  WeatherService.lookup(args["location"])
end
```

Then add tools to the session and ask normally:

```ruby
session = PromptBuilder::Session.new(model: "gpt-4o")
session.register_tool("weather",
  description: "Get the current weather for a location",
  parameters: {type: "object", properties: {location: {type: "string"}}, required: ["location"]}
)
session.user("What's the weather in NYC?")

PatientLLM.ask(session, provider: :openai, callback: LLMCallback)
```

When the model responds with tool calls, the gem automatically:

1. Appends the assistant tool-call response to the session.
2. Invokes the matching tool handler from the registry with the LLM-provided arguments.
3. Appends a tool-response item to the session.
4. Re-issues the request asynchronously.
5. Repeats until the model returns a plain text response (or a tool raises `HaltError`). Your `on_complete` callback only fires for the final text response.

If you define an optional `on_tool_use` method on your callback, it is invoked once per tool-execution round (after the tools run, before the next request is issued) so you can observe intermediate progress.

The loop is capped at `PatientLLM::Callback::MAX_TOOL_ITERATIONS` (10) iterations per conversation to prevent runaway calls. When the cap is exceeded, your `on_error` callback is invoked with a `PatientHttp::RequestError` whose `error_type` is `:max_tool_iterations` and whose `error_class` is `PatientLLM::MaxToolIterationsError`, so you can handle it alongside transport and HTTP errors.

> [!NOTE]
> Tool handlers execute synchronously inside the callback worker (e.g. a Sidekiq job). Keep handlers fast to avoid blocking the worker pool. If a tool needs to do slow work (external API calls, heavy queries), consider offloading that work and using `HaltError` to stop the auto-loop.

#### Halting the loop

Raise `PatientLLM::HaltError` from a tool handler to stop the auto-loop and surface custom content as the final assistant message:

```ruby
PromptBuilder.tool_registry.register("auth", description: "Authenticate", parameters: {...}) do |args|
  unless AuthService.valid?(args["token"])
    raise PatientLLM::HaltError.new(content: "Authentication failed.")
  end
  AuthService.session_info(args["token"])
end
```

### Serializing Conversations

Sessions can be serialized to JSON for storage and later restored:

```ruby
# Initial request
session = PromptBuilder::Session.new(model: "gpt-4o")
session.instructions = "You are a helpful assistant."
session.user("Hello!")

PatientLLM.ask(session, provider: :openai, callback: LLMCallback,
  callback_args: {conversation_id: conversation.id})

# In your callback, save the state (response is already in the session):
def on_complete(session:, callback_args:, **)
  save_to_database(callback_args[:conversation_id], session.to_h)
end

# Later, restore and continue:
session_data = load_from_database(conversation_id)
session = PromptBuilder::Session.from_h(session_data)
session.user("Tell me more about that.")

PatientLLM.ask(session, provider: :openai, callback: LLMCallback,
  callback_args: {conversation_id: conversation_id})
```

## Installation

This gem is not yet published to RubyGems. Add it from GitHub:

```ruby
gem "patient_llm", github: "bdurand/patient_llm"
```

Then execute:
```bash
$ bundle
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_llm).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
