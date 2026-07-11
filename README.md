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

## Quick start

Configure a provider (built-in presets know each vendor's URL, API format, and authentication header):

```ruby
PatientLLM.configure do |config|
  config.provider :anthropic, preset: :anthropic, api_key: -> { ENV["ANTHROPIC_API_KEY"] }
end
```

Define an agent:

```ruby
class TripPlannerAgent < PatientLLM::Agent
  provider :anthropic
  model "claude-sonnet-4-5"
  instructions "You are a travel assistant. Be concise."
  max_output_tokens 2_000

  tool :weather, "Get the weather forecast for a city" do
    param :city, :string, "City name", required: true
    param :country, :string
  end

  output do
    field :summary, :string, required: true
    field :packing_list, array: :string
  end

  # Tool handler: the instance method with the tool's name.
  def weather(city:, country: nil)
    WeatherService.forecast(city: city, country: country)
  end

  # Runs in the worker when the final response arrives (after any tool rounds).
  def completed(response, context)
    trip = Trip.find(context[:trip_id])
    trip.update!(plan: response.object, agent_state: response.state)
  end

  def failed(error, context)
    Rails.logger.error("Trip planning failed: #{error.error_type} #{error.message}")
  end
end
```

Call it:

```ruby
# Asynchronously through your job system:
TripPlannerAgent.ask("Plan a weekend in NYC", context: {trip_id: trip.id})

# Continue a saved conversation:
TripPlannerAgent.continue(trip.agent_state, "Make it kid-friendly", context: {trip_id: trip.id})

# Inline (blocking) for consoles, development, and tests:
response = TripPlannerAgent.ask!("Plan a weekend in NYC", context: {trip_id: trip.id})
response.text                 # the raw response text
response.object["summary"]    # parsed structured output per the output schema
response.usage.output_tokens  # token usage
```

Everything the agent declares stays in code — only JSON-safe data (the serialized conversation, the agent's class name, and your `context`) travels through the job queue. Tool handlers, API keys, and hooks are re-resolved in the worker process.

## Prerequisites

This gem delegates HTTP dispatch to `patient_http`. In production you get a request handler by adding one of the job-system integrations:

- [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq)
- [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue)

For development, consoles, and tests you can execute requests synchronously in-process instead:

```ruby
PatientHttp.inline!   # register the inline handler (no job system needed)
```

Verify everything is wired at boot (surfaces missing secrets, preprocessors, or handlers as boot errors instead of dispatch-time job failures):

```ruby
PatientLLM.verify_configuration!
```

## Configuration

### Provider presets

Presets bundle the vendor-specific details — base URL, API format, authentication header name, and key format:

```ruby
PatientLLM.configure do |config|
  config.provider :openai,    preset: :openai,    api_key: -> { ENV["OPENAI_API_KEY"] }
  config.provider :anthropic, preset: :anthropic, api_key: -> { ENV["ANTHROPIC_API_KEY"] }
  config.provider :gemini,    preset: :gemini,    api_key: -> { ENV["GEMINI_API_KEY"] }
  config.provider :bedrock,   preset: :bedrock,   region: "us-east-1", preprocessors: :aws_sigv4
end
```

The `api_key` is registered as a PatientHttp secret named `patient_llm.<provider>.api_key` and referenced from the provider's authentication header. The key value is resolved on the processor side at dispatch time and is **never serialized** into job payloads. Prefer a lambda (resolved lazily, supports rotation); a plain String also works.

Every preset value can be overridden, so pointing a preset at a proxy or gateway is one keyword:

```ruby
config.provider :my_proxy, preset: :openai, url: "https://llm-gateway.internal", api_key: -> { ENV["GATEWAY_KEY"] }
```

To keep managing your own secret names, pass a secret reference and no registration happens:

```ruby
config.provider :openai, preset: :openai, api_key: PatientHttp.secret("openai.bearer_token")
```

### Custom providers

Providers without a preset use the explicit form. Authentication headers must be secret references — inline API keys raise an error so keys can never end up serialized in the job queue:

```ruby
PatientLLM.configure do |config|
  config.provider :local, url: "http://localhost:1234", headers: {}

  config.provider :custom,
    url: "https://llm.internal",
    headers: {"x-api-key" => PatientHttp.secret("custom.api_key")},
    serializer: :messages,
    timeout: 300,               # per-provider request timeout (seconds)
    max_tool_iterations: 25     # per-provider tool loop cap
end

# Register the referenced secret with PatientHttp (can be done from any initializer;
# registrations are applied to the job integration's configuration whenever it configures):
PatientHttp.register_secret("custom.api_key") { ENV["CUSTOM_API_KEY"] }
```

Provider options: `url`, `headers`, `serializer`, `path`, `params` (merged into every payload), `preprocessors`, `timeout`, and `max_tool_iterations`.

### Request signing (preprocessors)

Some providers require request signing rather than a static authentication header — for example, AWS Bedrock with SigV4, where a signature is computed over the final outgoing request. For these, register a [request preprocessor](https://github.com/bdurand/patient_http#request-preprocessors) on the PatientHttp configuration and reference it by name from the provider. Like secrets, only the preprocessor name is serialized into the job queue; the signing logic and credentials stay on the processor side.

For SigV4, `PatientLLM::AwsRequestSigner` is a ready-made callable that can be registered directly as the preprocessor:

```ruby
PatientLLM.configure do |config|
  config.provider :bedrock, preset: :bedrock, region: "us-east-1", preprocessors: :aws_sigv4
end

PatientHttp::Sidekiq.configure do |config|
  config.register_preprocessor(:aws_sigv4, PatientLLM::AwsRequestSigner.new(
    credentials: Aws::CredentialProviderChain.new
  ))
end
```

`credentials:` is required and accepts a credential chain (anything responding to `resolve`, like `Aws::CredentialProviderChain`; resolved lazily on the first request), a credentials provider (responding to `credentials`), or a static credentials object (responding to `access_key_id` and `secret_access_key`, like `Aws::Credentials`). The signing `service:` and `region:` can be passed explicitly; when omitted they are derived from each request's URL host for standard `<service>.<region>.amazonaws.com` endpoints (`bedrock-runtime.us-east-1.amazonaws.com` signs as service `"bedrock"` in region `"us-east-1"`).

The signer needs the [aws-sigv4](https://rubygems.org/gems/aws-sigv4) gem, which is not a dependency of this gem — add it to your bundle (it is included with `aws-sdk-core`, which also provides the credential chain).

Multiple preprocessors can be given as an array; they run in order at dispatch time.

## Agents

`PatientLLM::Agent` is the high-level way to use this gem: one class declaring the provider, model, generation settings, tools, output schema, and completion handling.

### Declarations

```ruby
class ResearchAgent < PatientLLM::Agent
  provider :openai              # a registered provider name
  model "gpt-5"
  instructions "You are a research assistant."
  temperature 0.2
  max_output_tokens 4_000
  reasoning :medium             # portable effort level, or reasoning budget_tokens: 8_000
  max_tool_iterations 5         # tool loop cap for this agent (default 10)
end
```

### Tools

Declare the schema and define the handler together. The handler is the instance method with the tool's name, receiving the LLM-provided arguments as keywords:

```ruby
tool :search, "Search the knowledge base" do
  param :query, :string, "The search query", required: true
  param :limit, :integer
end

def search(query:, limit: nil)
  KnowledgeBase.search(query, limit: limit || 10)   # String or JSON-able return value
end
```

A raw JSON Schema hash is also accepted: `tool :search, "...", parameters: {...}`.

When the model responds with tool calls, the gem automatically executes the matching methods, appends the results to the session, and re-issues the request — until the model returns a plain text response or the iteration cap is reached. Your `completed` hook only fires for the final response; define `tool_round(response, context)` to observe intermediate rounds. Raise `PatientLLM::HaltError.new(content: "...")` from a tool method to stop the loop and surface the content as the final response.

Hooks receive the `context` passed to `ask`/`continue` as their second argument. A tool method that declares a `context:` keyword receives it too:

```ruby
def search(query:, context:)
  KnowledgeBase.for_user(context[:user_id]).search(query)
end
```

Inside hooks and tool methods the agent also exposes instance readers for the rest of the invocation state:

- `session` — the `PromptBuilder::Session` for the conversation
- `provider` — the provider name
- `last_http_response` — the `PatientHttp::Response` of the most recent HTTP exchange (status, headers, body, duration). In `completed` this is the final request's response; in `failed` it is nil for non-HTTP errors such as timeouts and connection failures.
- `last_http_request_id` — the request id of the most recent HTTP exchange (may also be nil for non-HTTP errors)

> [!NOTE]
> Tool handlers execute synchronously inside the callback worker (e.g. a Sidekiq job). Keep handlers fast to avoid blocking the worker pool. If a tool needs to do slow work, consider offloading it and using `HaltError` to stop the auto-loop.

### Structured output

```ruby
output do
  field :answer, :string, required: true
  field :confidence, :number
  field :sources, array: :object do
    field :title, :string
    field :url, :string
  end
end

def completed(response, context)
  response.object   # => parsed Hash matching the schema
end
```

`response.object` raises `PatientLLM::StructuredOutputError` (with the raw text attached) if the response cannot be parsed. A raw JSON Schema hash is also accepted: `output schema: {...}`.

### Multi-turn conversations

`response.state` is a JSON-native hash of the full conversation. Persist it anywhere, then continue:

```ruby
def completed(response, context)
  Conversation.find(context[:conversation_id]).update!(state: response.state)
end

# Later:
ResearchAgent.continue(conversation.state, "Tell me more about that", context: {conversation_id: conversation.id})
```

`continue` re-applies the agent's *current* instructions, tools, and output schema to the restored session, so deploying changes to an agent cleanly affects older conversations.

### Inline execution

`ask!` runs the request (and the whole tool loop) synchronously and returns the final response — no job system required. The `completed`/`failed` hooks still run, so tests exercise the real code paths:

```ruby
response = ResearchAgent.ask!("What is the capital of France?")
response.text   # => "Paris."
```

## The low-level API

Agents compile down to this API; use it directly when you need full control.

### Callback classes

Create a callback class with `on_complete` and `on_error` methods. Callbacks receive **keyword arguments**, and you only declare the ones you need — the dispatcher inspects your method signature and passes just those values (or everything if you declare `**kwargs`):

```ruby
class LLMCallback
  def on_complete(session:, provider:, llm_response:, callback_args:, http_response:, request_id:)
    # session       - the PromptBuilder::Session with the response already added
    # provider      - the provider name (String)
    # llm_response  - a PromptBuilder::Response with the assistant's response
    # callback_args - a PatientHttp::CallbackArgs containing data you passed in the `ask` call
    # http_response - the raw PatientHttp::Response
    # request_id    - the original request id (stable across tool-call iterations)

    puts llm_response.text
    puts "Tokens: #{llm_response.usage.input_tokens} in / #{llm_response.usage.output_tokens} out"

    save_session_state(callback_args[:user_id], session.to_h)
  end

  def on_error(session:, provider:, callback_args:, error:, http_response:, request_id:)
    # error is a PatientHttp::RequestError, ClientError (HTTP 4xx),
    # or ServerError (HTTP 5xx). All respond to:
    #   error.error_type  - :timeout, :connection, :ssl, :http_error, etc.
    #   error.message     - human-readable message
    #   error.error_class - the original exception class (for RequestError)
    #   error.request_id
    log_error(error.error_type, error.message)
  end
end
```

Each callback may declare any subset of the keywords below, in any order. `PatientLLM.ask` validates your callback's signatures up front and raises an `ArgumentError` if a method uses an unsupported name, a positional parameter, or omits the required keyword.

| Callback              | Supported keywords                                                          | Required       |
|-----------------------|-----------------------------------------------------------------------------|----------------|
| `on_complete`         | `session`, `provider`, `llm_response`, `callback_args`, `http_response`, `request_id` | `llm_response` |
| `on_tool_use` (optional) | `session`, `provider`, `llm_response`, `callback_args`, `http_response`, `request_id` | `llm_response` |
| `on_error`            | `session`, `provider`, `callback_args`, `error`, `http_response`, `request_id`        | `error`        |

### Making requests

Create a `PromptBuilder::Session` and call `PatientLLM.ask` to make an async request:

```ruby
session = PromptBuilder::Session.new(model: "gpt-4o")
session.instructions = "You are a helpful assistant."
session.user("What is the capital of France?")

PatientLLM.ask(session, provider: :openai, callback: LLMCallback, callback_args: {
  user_id: current_user.id
})
```

`PromptBuilder::Session` supports the full range of generation options, plus helpers for structured output, reasoning, and tools:

```ruby
session.temperature = 0.7
session.max_output_tokens = 1000
session.json_output(my_json_schema)      # structured output; parse with llm_response.parsed_json
session.think(effort: :medium)           # portable reasoning configuration
session.use_tools("weather", "search")   # attach tools registered on PromptBuilder.tool_registry
```

`PatientLLM.ask` accepts per-request overrides:

```ruby
PatientLLM.ask(session,
  provider: :openai,
  callback: LLMCallback,
  url: "http://localhost:1234",            # Override the provider's base URL
  serializer: :messages,                   # Override the API format
  path: "/chat/completions",               # Override the endpoint path
  headers: {"X-Custom" => "value"},        # Additional HTTP headers
  params: {max_completion_tokens: 1000},   # Additional request parameters
  preprocessors: :aws_sigv4,               # Replace the provider's request preprocessors
  timeout: 600,                            # Request timeout in seconds
  max_tool_iterations: 3                   # Tool loop cap for this request
)
```

`headers` and `params` are merged on top of the provider's configured values, while the other options replace the provider defaults. All overrides are preserved across automatic tool-loop iterations.

### Tool calling with the registry

Tools can also be registered on the global `PromptBuilder.tool_registry` with their handler, then attached to sessions by name — no schema duplication:

```ruby
PromptBuilder.register_tool(
  "weather",
  description: "Get the current weather for a location",
  parameters: {type: "object", properties: {location: {type: "string"}}, required: ["location"]}
) do |args|
  WeatherService.lookup(args["location"])
end

session.use_tools("weather")
PatientLLM.ask(session, provider: :openai, callback: LLMCallback)
```

The automatic tool loop works the same as with agents. When the cap is exceeded, `on_error` receives a `PatientHttp::RequestError` whose `error_type` is `:max_tool_iterations`.

### Inline execution

Run any request synchronously with `PatientLLM.inline`:

```ruby
PatientLLM.inline do
  PatientLLM.ask(session, provider: :openai, callback: LLMCallback)
end
```

Or register the PatientHttp inline handler globally for a console or test process with `PatientHttp.inline!`.

### URL composition

The full request URL is built by concatenating the base URL (from the provider registry or the `url:` option) with the `path`. When you don't set `path`, it defaults to the path for the active serializer (`/v1/chat/completions` for `:chat_completion`, `/v1/responses` for `:open_responses`, `/v1/messages` for `:messages`, `/converse` for `:converse`, `/v1beta/models/{model}:generateContent` for `:gemini`). A `{model}` placeholder in the path is replaced with the session's model at dispatch time. If your base URL already includes a `/v1` prefix, override the path to avoid duplication:

```ruby
PatientLLM.ask(session,
  provider: :openai,
  callback: LLMCallback,
  url: "https://my-gateway.internal/openai/v1",
  path: "chat/completions"
)
```

### Serializing conversations

Sessions serialize to JSON for storage and later restoration:

```ruby
# In your callback, save the state (the response is already in the session):
def on_complete(session:, callback_args:, **)
  save_to_database(callback_args[:conversation_id], session.to_h)
end

# Later, restore and continue:
session = PromptBuilder::Session.from_h(load_from_database(conversation_id))
session.user("Tell me more about that.")
PatientLLM.ask(session, provider: :openai, callback: LLMCallback)
```

### Session offload for large conversations

The serialized session travels through the job queue with each request. For conversations that can get large (e.g. with file attachments), configure automatic offloading to a [PatientHttp payload store](https://github.com/bdurand/patient_http#payload-stores):

```ruby
PatientLLM.configure do |config|
  config.session_offload payload_store: :s3, threshold: 65_536
end
```

Sessions above the threshold are written to the store and passed by reference. Offloaded payloads are not deleted after use (so job retries keep working); use a store with managed expiration such as a Redis TTL or an S3 lifecycle rule.

> [!NOTE]
> You can also set up encryption for your job payloads to ensure the entire serialized payload is always encrypted in the job queue. See the documentation for [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq#sensitive-data-handling) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue#sensitive-data-handling) for details.

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
