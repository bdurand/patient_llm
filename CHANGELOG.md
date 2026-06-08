# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.2.0

### Added

- Requires authentication headers to be set up as secrets using `PatientHttp.secret`. This is enforced and and error will be raised if plain text values are included for any of the following headers in the provider configuration: `authorization`, `x-api-key`, `x-goog-api-key`.

### Changed

- Requires patient_http version 1.1 or higher.

## 0.1.0

### Added

- Initial implementation: async OpenAI Chat Completions calls via `patient_http`.
- Tool calling with automatic execution loop and `halt` short-circuit via `PromptBuilder.tool_registry`.
- Provider registry, JSON-schema structured output, reasoning effort, custom headers/params.
- Session state serialization/restoration via `PromptBuilder::Session`.
