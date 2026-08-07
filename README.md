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
  system "You are a travel assistant. Be concise."
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
  def completed(response)
    trip = Trip.find(response.context[:trip_id])
    trip.update!(plan: response.object, agent_state: response.state)
  end

  def failed(failure)
    Rails.logger.error("Trip planning failed: #{failure.error_type} #{failure.message}")
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

Everything the agent declares stays in code — only JSON-safe data (the serialized conversation, the agent's class name, your `context`, and the resolved request metadata: provider and serializer names, per-request overrides, and tool-loop counters) travels through the job queue. Tool handlers, API keys, and hooks are re-resolved in the worker process.

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
  config.provider :openai, preset: :openai, api_key: -> { ENV["OPENAI_API_KEY"] }
  config.provider :anthropic, preset: :anthropic, api_key: -> { ENV["ANTHROPIC_API_KEY"] }
  config.provider :gemini, preset: :gemini, api_key: -> { ENV["GEMINI_API_KEY"] }
  config.provider :bedrock, preset: :bedrock_runtime, region: "us-east-1", preprocessors: :aws_sigv4
end
```

The `api_key` is registered as a PatientHttp secret named `patient_llm.<provider>.api_key` and referenced from the provider's authentication header. The key value is resolved on the processor side at dispatch time and is **never serialized** into job payloads. Prefer a lambda (resolved lazily, supports rotation); a plain String also works.

Bedrock supports two authentication styles: pass `api_key:` with an [Amazon Bedrock API key](https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html) (sent as a bearer token), or sign requests with IAM credentials using SigV4 as shown above — see [request signing](#request-signing-preprocessors).

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

Provider options: `url`, `headers`, `serializer`, `path`, `params` (merged into every payload), `preprocessors`, `timeout`, `max_tool_iterations`, `api_key` (see [provider presets](#provider-presets)), and `region` (used by region-templated presets such as `:bedrock_runtime`).

Every provider option (except `name`, `preset`, and `api_key`) may also be a callable, evaluated each time the provider is looked up — i.e. on every request — so values can be generated dynamically at runtime (`api_key` is consumed at registration time to build the authentication header; a callable key is resolved on the processor side at dispatch):

```ruby
PatientLLM.configure do |config|
  config.provider :gateway,
    url: -> { LLMConfiguration.gateway_url },
    timeout: -> { LLMConfiguration.request_timeout }
end
```

Validation of a callable's result (serializer names, authentication headers) happens at lookup time instead of registration time.

### Request signing (preprocessors)

Some providers require request signing rather than a static authentication header — for example, AWS Bedrock with SigV4, where a signature is computed over the final outgoing request. For these, register a [request preprocessor](https://github.com/bdurand/patient_http#request-preprocessors) on the PatientHttp configuration and reference it by name from the provider. Like secrets, only the preprocessor name is serialized into the job queue; the signing logic and credentials stay on the processor side.

For SigV4, `PatientLLM::AwsRequestSigner` is a ready-made callable that can be registered directly as the preprocessor:

```ruby
PatientLLM.configure do |config|
  config.provider :bedrock, preset: :bedrock_runtime, region: "us-east-1", preprocessors: :aws_sigv4
end

PatientHttp::Sidekiq.configure do |config|
  config.register_preprocessor(:aws_sigv4, PatientLLM::AwsRequestSigner.new(
    credentials: Aws::CredentialProviderChain.new
  ))
end
```

`credentials:` is required and accepts a credential chain (anything responding to `resolve`, like `Aws::CredentialProviderChain`; resolved lazily on the first request), a credentials provider (responding to `credentials`), or a static credentials object (responding to `access_key_id` and `secret_access_key`, like `Aws::Credentials`). The signing `service:` and `region:` can be passed explicitly; when omitted they are derived from each request's URL host for standard `<service>.<region>` AWS endpoints, including dual-stack `api.aws` hosts (`bedrock-runtime.us-east-1.amazonaws.com` signs as service `"bedrock"` in region `"us-east-1"`; `bedrock-mantle.us-east-1.api.aws` signs under its own `"bedrock-mantle"` service name).

The signer needs the [aws-sigv4](https://rubygems.org/gems/aws-sigv4) gem, which is not a dependency of this gem — add it to your bundle (it is included with `aws-sdk-core`, which also provides the credential chain).

Multiple preprocessors can be given as an array; they run in order at dispatch time.

## Agents

`PatientLLM::Agent` is the high-level way to use this gem: one class declaring the provider, model, generation settings, tools, output schema, and completion handling.

### Declarations

```ruby
class ResearchAgent < PatientLLM::Agent
  provider :openai              # a registered provider name
  model "gpt-5"
  system "You are a research assistant."
  instructions "Cite your sources."
  temperature 0.2
  max_output_tokens 4_000
  reasoning :medium             # portable effort level, or reasoning budget_tokens: 8_000
  max_tool_iterations 5         # tool loop cap for this agent (default 10)
  extra guardrail_config: {guardrailIdentifier: "gr-1", guardrailVersion: "1"}
end
```

`instructions` sets system-level instructions for the request. On APIs without a separate instructions field they are appended to the system prompt.

`extra` sets provider-specific extra data on every session the agent builds. The recognized keys depend on the serializer used for the request — for example, the Bedrock Converse serializer maps `guardrail_config`, `stop_sequences`, `additional_model_request_fields`, and `performance_config` into the request payload (see the prompt_builder docs for each serializer's keys). Redeclaring `extra` in a subclass replaces the whole hash, and `continue` re-applies the agent's current value to restored sessions. A per-request `ask(extra: {...})` replaces the declaration for that request; to add to it instead, merge explicitly: `MyAgent.ask(msg, extra: MyAgent.extra.merge(...))`. Session options such as `extra:` are only accepted when `ask` builds the session — passing them to `continue`, or together with a `session:`, raises `ArgumentError`.

### Dynamic values

Every scalar declaration (`provider`, `model`, `system`, `instructions`, `temperature`, `max_output_tokens`, `max_tool_iterations`, and `extra`) also accepts a block in lieu of the argument, or a callable (anything responding to `call`) as the argument. The block or callable is evaluated each time the agent builds or sends a request, so the value can be generated dynamically at runtime:

```ruby
class ResearchAgent < PatientLLM::Agent
  extra { LLMConfiguration.extra_hash }
  temperature -> { AppConfig.llm_temperature }
end
```

Validation and coercion (`extra`'s Hash check, `provider`'s symbol coercion) apply to the block's result each time it is evaluated.

### Inheritance

Subclasses inherit every declaration from their parent agent class, including tools and the output schema — so a base agent can hold shared configuration while subclasses specialize. Inheritance is live: getters fall back to the parent class, so declarations added to the parent later are visible to existing subclasses.

Override a setting by redeclaring it, or remove an inherited scalar setting by passing an explicit `nil` (tools and the output schema cannot be removed this way):

```ruby
class BaseAgent < PatientLLM::Agent
  provider :openai
  model "gpt-5"
  temperature 0.2

  tool :search, "Search the knowledge base" do
    param :query, :string, required: true
  end
end

class CreativeAgent < BaseAgent
  temperature 0.9     # override
end

class DefaultTemperatureAgent < BaseAgent
  temperature nil     # remove: use the provider's default temperature
end
```

Tools merge by name — redeclaring a tool in a subclass replaces the inherited declaration for that subclass only.

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

When the model responds with tool calls, the gem automatically executes the matching methods, appends the results to the session, and re-issues the request — until the model returns a plain text response or the iteration cap is reached. Your `completed` hook only fires for the final response; define `tool_round(response)` to observe intermediate rounds. Raise `PatientLLM::HaltError.new(content: "...")` from a tool method to stop the loop and surface the content as the final response.

### Hooks

Each hook receives a single object bundling the whole invocation:

- `completed(response)` and `tool_round(response)` receive a `PatientLLM::Agent::Response` exposing `text`, `object` (parsed structured output; `completed` only — an intermediate `tool_round` response has none, and calling `object` there raises `StructuredOutputError`), `state` (the serializable session), `usage`, `model`, `tool_calls`, `session`, `context` (what you passed to `ask`/`continue`), `http_response` (the `PatientHttp::Response` — status, headers, body, duration), and `http_request_id`. In `completed` the HTTP exchange is the final request's; in `tool_round` it is that round's.
- `failed(failure)` receives a `PatientLLM::Agent::Failure` exposing the `error` (with `error_type`, `message`, and `error_class` delegated for convenience) alongside the same `session`, `state`, `context`, `http_response`, and `http_request_id`. The `http_response` is nil for non-HTTP errors such as timeouts and connection failures.

Both objects support `[]` as a shorthand for reading a context value, so `response[:trip_id]` is the same as `response.context[:trip_id]` (and raises `KeyError` if the key was not passed to `ask`/`continue`).

```ruby
def completed(response)
  Trip.find(response[:trip_id]).update!(itinerary: response.object)
end
```

A tool method that declares a `context:` keyword receives the context too:

```ruby
def search(query:, context:)
  KnowledgeBase.for_user(context[:user_id]).search(query)
end
```

Inside hooks and tool methods the agent also exposes `session` and `provider` instance readers.

### Overriding the hooks per request

Pass `callback:` to `ask`, `continue`, or `ask!` to send the hooks to another class instead of the agent. The agent still supplies the provider, model, tools, and output schema — only the hooks move:

```ruby
class TripCallbacks
  def completed(response)
    Trip.find(response[:trip_id]).update!(itinerary: response.object)
  end

  def failed(failure)
    ErrorReporter.notify(failure.error, trip_id: failure[:trip_id])
  end
end

TripPlannerAgent.ask("Plan a weekend in NYC", context: {trip_id: trip.id}, callback: TripCallbacks)
```

The class is instantiated fresh in the worker for each invocation and may implement any subset of `completed`, `failed`, and `tool_round`; a hook it doesn't implement falls back to the agent's own. Only the class *name* travels through the queue, so it must be a named, resolvable class — an anonymous class raises `ArgumentError`, and one implementing none of the three hooks raises `ArgumentError` when `ask` is called.

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

def completed(response)
  response.object   # => parsed Hash matching the schema
end
```

`response.object` raises `PatientLLM::StructuredOutputError` (with the raw text attached) if the response cannot be parsed. A raw JSON Schema hash is also accepted: `output schema: {...}`.

### Multi-turn conversations

`response.state` is a JSON-native hash of the full conversation. Persist it anywhere, then continue:

```ruby
def completed(response)
  Conversation.find(response.context[:conversation_id]).update!(state: response.state)
end

# Later:
ResearchAgent.continue(conversation.state, "Tell me more about that", context: {conversation_id: conversation.id})
```

`continue` re-applies the agent's *current* model, system, tools, and output schema to the restored session, so deploying changes to an agent cleanly affects older conversations.

Passing an existing `session:` to `ask` is different: the session is sent as-is and the agent's declarations (model, system, tools, output schema) are **not** applied to it. Use `continue` for restored conversations.

### Inline execution

`ask!` runs the request (and the whole tool loop) synchronously and returns the final response — no job system required. The `completed`/`failed` hooks still run, so tests exercise the real code paths:

```ruby
response = ResearchAgent.ask!("What is the capital of France?")
response.text   # => "Paris."
```

### Previewing requests

`preview_request` builds the request that `ask` would send — through the same resolution logic — without sending anything. It returns a `PatientLLM::RequestPreview` with the resolved `url`, `headers`, and JSON `payload`. Header values that reference registered secrets are replaced with placeholders, and request preprocessors (which run at send time) are not applied:

```ruby
preview = ResearchAgent.preview_request("What is the capital of France?")
preview.url       # => "https://api.openai.com/v1/chat/completions"
preview.payload   # => {"model" => "gpt-4o", "messages" => [...], ...}
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

Each callback may declare any subset of the keywords below, in any order. `PatientLLM.ask` validates your callback's signatures up front and raises an `ArgumentError` if a method uses an unsupported name or a positional parameter, or if `on_error` omits its required `error` keyword.

| Callback              | Supported keywords                                                          | Required       |
|-----------------------|-----------------------------------------------------------------------------|----------------|
| `on_complete`         | `session`, `provider`, `llm_response`, `callback_args`, `http_response`, `request_id` | —              |
| `on_tool_use` (optional) | `session`, `provider`, `llm_response`, `callback_args`, `http_response`, `request_id` | —              |
| `on_error`            | `session`, `provider`, `callback_args`, `error`, `http_response`, `request_id`        | `error`        |

### Making requests

Create a `PromptBuilder::Session` and call `PatientLLM.ask` to make an async request:

```ruby
session = PromptBuilder::Session.new(model: "gpt-4o")
session.system("You are a helpful assistant.")
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

`PatientLLM.preview_request` accepts the same arguments (minus `callback:`) and returns the request that `ask` would send — a `PatientLLM::RequestPreview` with the resolved `url`, `headers` (secret values redacted), and JSON `payload` — without enqueuing or executing anything:

```ruby
preview = PatientLLM.preview_request(session, provider: :openai)
preview.payload   # => {"model" => "gpt-4o", "messages" => [...]}
```

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

The full request URL is built by concatenating the base URL (from the provider registry or the `url:` option) with the `path`. When you don't set `path`, it defaults to the path for the active serializer (`v1/chat/completions` for `:chat_completion`, `v1/responses` for `:open_responses`, `v1/messages` for `:messages`, `model/{model}/converse` for `:converse`, `v1beta/models/{model}:generateContent` for `:gemini`). A `{model}` placeholder in the path is replaced with the session's model, percent-encoded as a single path segment, at dispatch time. If your base URL already includes a `/v1` prefix, override the path to avoid duplication:

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
