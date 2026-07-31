# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.5.0

### Added

- Added `PatientLLM::Agent`, a declarative base class bundling provider, model, system, generation settings, tools (schema and handler together as instance methods), structured output schema, and completion handling in one class. Call with `MyAgent.ask(message, context: {...})`, continue persisted conversations with `MyAgent.continue(state, message)` (the agent's current configuration is re-applied to the restored session), and run inline for consoles and tests with `MyAgent.ask!`. Declarations accept blocks or callables resolved at request time, and `extra` declares provider-specific session data. Responses are handled by `completed(response)`, `failed(failure)`, and `tool_round(response)` hooks, redirectable to another class with the `callback:` option: successes receive an `Agent::Response` and failures an `Agent::Failure`, each bundling the whole invocation — the context passed to `ask`/`continue`, the HTTP exchange (`http_response`/`http_request_id`, nil for non-HTTP errors), the session, and the response text/structured output (`object`, which raises `PatientLLM::StructuredOutputError` when parsing fails) or error. Both objects support `[]` as a shorthand for reading a context value (`response[:trip_id]`). Tool methods can opt into the context by declaring a `context:` keyword.
- Added `PatientLLM::Schema`, a minimal JSON Schema builder used by the Agent DSL for tool parameters and output schemas. Raw JSON Schema hashes are accepted everywhere as an escape hatch.
- Added built-in provider presets (`:openai`, `:anthropic`, `:gemini`, `:bedrock_runtime`) supplying each vendor's URL, serializer, authentication header, and API key format: `config.provider :anthropic, preset: :anthropic, api_key: -> { ENV["ANTHROPIC_API_KEY"] }`. `url:` is no longer required when a preset supplies it; `:bedrock_runtime` requires a `region:` option instead. The `api_key` option registers the key as a PatientHttp secret named `patient_llm.<provider>.api_key` automatically — no separate `register_secret` step or hand-matched name strings.
- Added `PatientLLM.verify_configuration!` to check at boot time that a request handler is registered and that every secret and preprocessor referenced by a provider is registered.
- Added `timeout:` and `max_tool_iterations:` options to provider configuration and `PatientLLM.ask`. Both are preserved across automatic tool-loop iterations.
- Provider configuration options can now be callables, evaluated each time the provider is looked up so values can be generated dynamically at runtime. Validation of a callable's result happens at lookup time.
- Added `PatientLLM.inline { ... }` to execute requests (including the automatic tool loop) synchronously in-process without a job-system handler.
- Added optional session offloading for large conversations: `config.session_offload payload_store: :name, threshold: bytes` stores oversized sessions in a PatientHttp payload store and passes them by reference through the job queue.
- The automatic tool loop can now resolve tool handlers from the user callback itself when it implements `handles_tool?`/`invoke_tool` (as `PatientLLM::Agent` does), falling back to the global `PromptBuilder.tool_registry`.
- Added `PatientLLM::AwsRequestSigner`, a callable helper for signing requests with AWS SigV4 that can be registered directly as a PatientHttp request preprocessor (e.g. for Bedrock). It takes a credential chain, credentials provider, or static credentials object, and derives the signing service and region from the request URL host when not given explicitly. Requires the aws-sigv4 gem, which is not a dependency of this gem.

### Changed

- The serializer is now resolved once at enqueue time and travels with the request, so the response is always parsed with the same format the payload was built with even if provider configuration differs between processes.
- `MAX_TOOL_ITERATIONS` is now a default rather than a hard cap; the resolved limit travels with the request.
- The default `:converse` path is now `model/{model}/converse` (was `converse`), and the model substituted into a `{model}` placeholder is percent-encoded so Bedrock ARN model ids form a single path segment.
- The hardcoded `/v1/chat/completions` last-resort path fallback was removed, and a `{model}` placeholder with no session model now raises `ArgumentError`.
- Callback args are deep-converted to JSON-native values (previously only the top-level keys were stringified).
- When a tool halts the loop, the remaining tool calls in that round receive a "Tool execution halted" output instead of being skipped, and the synthesized halt message no longer advances the session's response boundary.
- Requires patient_http 1.3 and prompt_builder 0.3.
- Minimum Ruby version is now 3.2.

### Removed

- Removed the deprecated `completion_path:` argument from `PatientLLM.ask` and provider configuration; use `path:`.
- Removed the internal `tool_iteration:` and `original_request_id:` arguments from the public `PatientLLM.ask` signature.

## 0.4.0

### Added

- Added `preprocessors:` option to provider configuration and `PatientLLM.ask` for applying named PatientHttp request preprocessors (e.g., AWS SigV4 request signing) at dispatch time. A per-request value replaces the provider default; pass an empty array to clear it for a single request.

### Changed

- Requires patient_http version 1.2 or higher.

## 0.3.0

### Changed

- Renamed the `completion_path` argument to `path` on both `PatientLLM.ask` and provider configuration. The `completion_path` name is still accepted as a deprecated alias and now emits a deprecation warning.
- The path is now joined with the base URL using `URI.join` to ensure proper handling of relative paths in the `path` argument. If the path starts with a slash, it will be treated as an absolute path and will replace the base URL's path. If it does not start with a slash, it will be treated as a relative path and will be appended to the base URL's path.

## 0.2.0

### Added

- Requires authentication headers to be set up as secrets using `PatientHttp.secret`. This is enforced and an error will be raised if plain text values are included for any of the following headers in the provider configuration: `authorization`, `x-api-key`, `x-goog-api-key`, `api-key`.

### Changed

- Requires patient_http version 1.1 or higher.

## 0.1.0

### Added

- Initial implementation: async OpenAI Chat Completions calls via `patient_http`.
- Tool calling with automatic execution loop and `halt` short-circuit via `PromptBuilder.tool_registry`.
- Provider registry, JSON-schema structured output, reasoning effort, custom headers/params.
- Session state serialization/restoration via `PromptBuilder::Session`.
