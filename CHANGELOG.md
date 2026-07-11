# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.5.0

### Added

- Added `PatientLLM::Agent`, a declarative base class bundling provider, model, instructions, generation settings, tools (schema and handler together as instance methods), structured output schema, and completion handling in one class. Call with `MyAgent.ask(message, context: {...})`, continue persisted conversations with `MyAgent.continue(state, message)`, and run inline for consoles and tests with `MyAgent.ask!`. Responses are handled by `completed(response, context)`, `failed(error, context)`, and `tool_round(response, context)` hooks; tool methods can opt into the context by declaring a `context:` keyword; and the `last_http_response`/`last_http_request_id` readers expose the most recent HTTP exchange (nil for non-HTTP errors).
- Added `PatientLLM::Schema`, a minimal JSON Schema builder used by the Agent DSL for tool parameters and output schemas. Raw JSON Schema hashes are accepted everywhere as an escape hatch.
- Added built-in provider presets (`:openai`, `:anthropic`, `:gemini`, `:bedrock`) supplying each vendor's URL, serializer, authentication header, and API key format: `config.provider :anthropic, preset: :anthropic, api_key: -> { ENV["ANTHROPIC_API_KEY"] }`. The `api_key` option registers the key as a PatientHttp secret named `patient_llm.<provider>.api_key` automatically — no separate `register_secret` step or hand-matched name strings.
- Added `PatientLLM.verify_configuration!` to check at boot time that a request handler is registered and that every secret and preprocessor referenced by a provider is registered.
- Added `timeout:` and `max_tool_iterations:` options to provider configuration and `PatientLLM.ask`. Both are preserved across automatic tool-loop iterations.
- Added `PatientLLM.inline { ... }` to execute requests (including the automatic tool loop) synchronously in-process without a job-system handler.
- Added optional session offloading for large conversations: `config.session_offload payload_store: :name, threshold: bytes` stores oversized sessions in a PatientHttp payload store and passes them by reference through the job queue.
- The automatic tool loop can now resolve tool handlers from the user callback itself when it implements `handles_tool?`/`invoke_tool` (as `PatientLLM::Agent` does), falling back to the global `PromptBuilder.tool_registry`.
- Added `PatientLLM::AwsRequestSigner`, a callable helper for signing requests with AWS SigV4 that can be registered directly as a PatientHttp request preprocessor (e.g. for Bedrock). It takes a credential chain, credentials provider, or static credentials object, and derives the signing service and region from the request URL host when not given explicitly. Requires the aws-sigv4 gem, which is not a dependency of this gem.

### Changed

- The serializer is now resolved once at enqueue time and travels with the request, so the response is always parsed with the same format the payload was built with even if provider configuration differs between processes.
- `MAX_TOOL_ITERATIONS` is now a default rather than a hard cap; the resolved limit travels with the request.
- Requires patient_http 1.3 and prompt_builder 0.2.

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
