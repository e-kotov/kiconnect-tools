# KI:connect CLI (`kiconnect-tools`)

A simple, minimal-dependency Bash CLI interface for the [KI:connect](https://chat.kiconnect.nrw/) AI service API.

This client provides a minimalistic way to inspect models, check capabilities, and interact with KI:connect endpoints directly from your terminal, making it ideal for quick testing, shell pipelines, and agent harness setup.

## Features

- **Pure Live Data**: `models` displays live metadata directly from `/v1/models` without hardcoded assumptions.
- **Dynamic Backend Probing**: `models -p/--probe` (or `models <model>`) queries endpoints live to uncover the exact upstream model snapshot (e.g. `gpt-5.6-terra-2026-07-09`, `gpt-5-mini-2025-08-07`), runtime engine (`Azure OpenAI`, `vllm-0.29.0-...`), latency, and health.
- **Pipeline Friendly**: `models --short` (or `-s`) outputs plain model IDs for UNIX pipes. `models --json` prints raw API output.
- **Multi-Endpoint Support**: Default connects to `https://chat.kiconnect.nrw/api/v1`, with support for custom gateways or proxies via `-e` or `KICONNECT_ENDPOINT`.
- **Inference Support**: Single-shot chat completions (`ki chat "prompt"`), modern responses endpoint (`ki response "prompt"`), and embeddings (`ki embed "text"`), including reading from `stdin` (`-`).
- **Minimal Dependencies**: Requires only common system tools: `curl` and `jq`.

## Installation

Because this is a single-file script, you do not need to clone the repository. You can download it directly into your local `bin` directory:

```bash
# 1. Ensure the local bin directory exists
mkdir -p ~/.local/bin

# 2. Download the script directly to your path
curl -o ~/.local/bin/ki https://raw.githubusercontent.com/e-kotov/kiconnect-tools/main/ki.sh

# 3. Make it executable
chmod +x ~/.local/bin/ki

# 4. Optional: create kiconnect symlink
ln -sf ~/.local/bin/ki ~/.local/bin/kiconnect
```
*(Ensure `~/.local/bin` is in your `$PATH` environment variable).*

## Authentication

The script requires a KI:connect API key. You can provide it in three ways:

1. **Environment Variable**:
   ```bash
   export KICONNECT_API_KEY='your_key_here'
   ```
2. **.env File**: Create a `.env` file in the working directory:
   ```bash
   KICONNECT_API_KEY=your_key_here
   ```
3. **macOS Keychain**: If on macOS, `ki` automatically retrieves `kiconnect_api_key` from your system keychain if `KICONNECT_API_KEY` is not set.

## Usage

Run the script without arguments to see the help menu:
```bash
./ki.sh
```

### Examples

**List available models (Fast, 1 API call, pure live data):**
```bash
ki models
```
Example output:
```text
MODEL                    OWNED BY        CREATED
GPT5-Mitarbeitende       tu-dortmund.de  2026-09-25T13:00:51Z
GPT5-mini-Mitarbeitende  tu-dortmund.de  2026-09-25T13:00:51Z
OpenAI GPT OSS 120B      tu-dortmund.de  2026-09-25T13:00:51Z
qwen3.8-27b              tu-dortmund.de  2026-09-25T13:00:51Z
```

**Probe all models live (Discovers exact upstream snapshots and runtimes):**
```bash
ki models --probe
```
Example output:
```text
MODEL                    UPSTREAM SNAPSHOT         RUNTIME / ENGINE          LATENCY    STATUS
GPT5-mini-Mitarbeitende  gpt-5-mini-2025-08-07     Azure OpenAI              1.34s      ok
GPT5-Mitarbeitende       gpt-5.6-terra-2026-07-09  Azure OpenAI              1.52s      ok
OpenAI GPT OSS 120B      openai/gpt-oss-120b       vllm-0.29.0-cf832eda      0.25s      ok
qwen3.8-27b              qwen3-8-27b               vllm-0.29.0-tp2-a4aae52c  0.95s      ok
```

**Probe a single model (Consumes only 1 token request):**
```bash
ki models qwen3.8-27b
```

**Pipeline model IDs:**
```bash
ki models --short
```

**Raw JSON:**
```bash
ki models --json | jq .
```

**Chat with an LLM (Simple):**
```bash
ki chat "Explain the difference between v1/responses and v1/chat/completions"
```

**Chat with an LLM (Custom system prompt + stdin):**
```bash
cat code.py | ki chat "You are a code reviewer" -
```

**Model Response via `/v1/responses`:**
```bash
ki response "Explain quantum computing briefly"
cat prompt.txt | ki response - GPT5-Mitarbeitende
```

**Embeddings via `/v1/embeddings`:**
```bash
ki embed "Vectorize this sentence"
```

**Query via custom proxy/gateway:**
```bash
ki -e http://127.0.0.1:47831/v1 models
```

## Dependencies

- `curl`
- `jq`

## License

MIT License. See [LICENSE](LICENSE) for details.
