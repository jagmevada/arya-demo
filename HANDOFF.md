# Arya voice demo: handoff for the office workstation

Status on 11 November 2026. Page version 78. Everything below was developed and tested from a phone against hosted services; nothing has yet been run on office hardware.

## 1. Get it running

```bash
git clone https://github.com/jagmevada/arya-demo.git
cd arya-demo
python3 -m http.server 8080
```

Open `http://localhost:8080` in Chrome on the same machine. The microphone works on `localhost` without HTTPS; from any other machine the page must be served over HTTPS.

The whole app is `index.html`. There is no build step and no dependency to install.

In Settings, enter:

| Field | Value |
|---|---|
| Cartesia API key | From play.cartesia.ai. Needs internet until speech runs locally |
| Brain | "Open model" |
| Provider | "Local: vLLM or llama.cpp on this machine" (`http://localhost:8000/v1`) or "Local: Ollama" (`http://localhost:11434/v1`) |
| Model name | The name the local server reports, for example `Qwen/Qwen3.8-27B-FP8` |
| Key | Any text if the local server does not check keys |

Keys are stored only in the browser (`localStorage`). Never commit a key: this repository is public.

## 2. Model decision

| Point | Decision |
|---|---|
| Model | Qwen 3.8 27B. Judged best overall in the voice runs |
| Precision | Official FP8 checkpoint, about 31 GB on disk and about 40 GB of memory with a small cache. Not 4-bit |
| Why not 4-bit | Cerebras served the tested model at 16-bit. The requirement is to deploy nothing weaker than what was tested. Qwen publishes only BF16 and FP8 as official weights |
| Target board | NVIDIA Jetson T4000, 64 GB shared memory. FP8 leaves about 24 GB for speech models. A 32 GB machine is ruled out |
| Hindi | Open point. Qwen's Hindi writing was unreliable in early runs and acceptable in the last one. Options: English replies only, or "Hindi by translation" |

The OpenRouter runs did not record which host or precision answered. Only the Cerebras runs are known to be 16-bit.

## 3. Serving the model locally

Run on 11 November 2026 on an RTX 6000 Ada (48 GB) with vLLM 0.28.0. Use the script in this repository:

```bash
hf download Qwen/Qwen3.8-27B-FP8      # once, about 29 GB
./serve-brain.sh                      # GPU=1 ./serve-brain.sh for another GPU
```

It runs:

```bash
HF_HUB_OFFLINE=1 vllm serve Qwen/Qwen3.8-27B-FP8 \
  --host 0.0.0.0 --port 8000 \
  --max-model-len 32768 --max-num-seqs 16 \
  --language-model-only \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --allowed-origins '["http://localhost:8080","http://127.0.0.1:8080"]'
```

Measured: about 0.7 s for a short answer; a correct tool call; CORS allowed for the page; no hidden reasoning tokens.

Notes:

- The tool parser is `qwen3_coder` (per the vLLM Qwen3.8 recipe), not `hermes` as first assumed.
- `--max-num-seqs 16` is required. The default 256 exceeds this hybrid model's state cache on a 48 GB card and startup fails.
- `HF_HUB_OFFLINE=1`: the weights are local. Without it vLLM contacts Hugging Face at start, and a CDN error there made startup fail.
- Download into the cache vLLM will read (`HF_HOME`). A model downloaded into another cache folder is not found.
- The official FP8 model card says not to pass `--quantization fp8`; the setting is read from the checkpoint.
- The page calls the server from the browser, so the server must allow the page's origin (CORS). Without it every call fails with a network error.
- Thinking is switched off on the server. The page only sends its "no reasoning" option to OpenRouter.
- In Settings, choose the provider first and then type the model name: changing the provider clears the model name field.

Memory on the 48 GB card: the weights take 27.6 GB. vLLM reserves 90 % of the card by default (41.8 GB in use), mostly cache Arya does not need; one 7,000-token turn needs well under 1 GB. A realistic total is 31 to 33 GB of GPU memory plus about 4.5 GB of system memory for vLLM itself. On a device where GPU and system memory are shared, FP8 needs about 36 to 37 GB including the operating system, so a 32 GB device does not fit it.

## 4. First tests at the office

1. Settings → Test. Confirms microphone, Cartesia and the brain in one step.
2. Settings → Load model list → Test listed models. The built-in 27-task test. Record the score, the time per answer and GPU memory in use.
3. One voice run with the trap questions (list at the end of `INTEGRATION.md`, section 12). Use "Copy log for diagnosis" and keep the log.
4. Compare FP8 with BF16 on the same test if a machine with enough memory is available.

Each voice run uses Cartesia credits. The account was at 75 % of its monthly credits on 10 November.

## 5. Open items

| Item | State |
|---|---|
| Cartesia offline (Ink and Sonic self-hosted) | Email sent 10 November to support@cartesia.ai asking for minimum memory, Jetson (ARM64) support, Hindi in self-hosted versions, single-node Docker and an evaluation licence. No reply yet. The copy to karan@mail.cartesia.ai bounced |
| Precision pinning on OpenRouter | Not implemented. The page could request FP8 only and log the serving host, so hosted tests match the deployment |
| Office launch simulator | Not connected. Replace `snapshot()`, `nextEvents()`, `nextContacts()` and `runTool()`; keep the tool names. See `INTEGRATION.md`, section 2 |
| Timeline, limits and procedures | All demo placeholders. Replace with approved data |
| `ARYA.md` persona file (in the Claude project) | Still the old English-only version. The page carries its own prompt |
| Smaller model by fine-tuning | Idea only. Log every office test turn (snapshot, question, accepted answer) so the data exists if a 4B to 14B student is trained later |

## 6. Where things are

| What | Where |
|---|---|
| App | `index.html` |
| Design, tools, reminder code, prompt rules, model comparison, air-gapped plan | `INTEGRATION.md` |
| Live page | https://jagmevada.github.io/arya-demo/ |
| Baseline before the conversation-style change | branch `v48-baseline` |

Rules that have saved time: bump `VERSION` in `index.html` on every change (it is shown at the bottom of the page and in every copied log), and never put a `//` comment in the middle of a line of code.
