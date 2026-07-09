# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
