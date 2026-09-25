# Changelog

All notable changes to `kiconnect-tools` will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-09-25

### Added

- Initial release of `ki.sh` (`ki`), a minimalistic, dependency-light Bash CLI client for the KI:connect AI service API (`https://chat.kiconnect.nrw/api/v1`).
- `models`: Formatted table rendering live metadata directly from `/v1/models` (`MODEL`, `OWNED BY`, `CREATED`).
  - `-p` / `--probe`: Dynamic live completion probing to discover exact upstream model snapshots (e.g. `gpt-5.6-terra-2026-07-09`, `gpt-5-mini-2025-08-07`, `openai/gpt-oss-120b`, `qwen3-8-27b`), runtime engine/fingerprint (`Azure OpenAI`, `vllm-0.29.0-...`), round-trip latency, and health status.
  - `models <model>`: Targeted probe for a single model (consumes only 1 completion request).
  - `-s` / `--short` / `--ids`: Plain model IDs for UNIX pipelines.
  - `--json`: Raw JSON API output.
- `chat`: Single-shot chat completions via `/v1/chat/completions` with optional system prompt and stdin (`-`) support.
- `response` / `res`: Modern response generation via `/v1/responses` with streaming text extraction and stdin (`-`) support.
- `embed`: Vector embeddings generation via `/v1/embeddings` with stdin (`-`) and raw JSON support.
- Multi-tier authentication: `KICONNECT_API_KEY` environment variable, local `.env` file, and macOS Keychain lookup (`kiconnect_api_key`).
- Custom endpoint configuration via `-e` / `--endpoint` and `KICONNECT_ENDPOINT` environment variable.
- Comprehensive end-to-end test suite (`tests/test_e2e.sh`) with self-contained mock curl runner (43 assertions).
