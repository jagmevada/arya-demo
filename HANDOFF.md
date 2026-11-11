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
./serve-brain.sh                      # GPU=1 for another GPU; MTP=0 turns speculative decoding off
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

## 3a. Speed on edge hardware (Jetson T4000) and what was tried

Measured on 11 November 2026 on an RTX 6000 Ada slowed to Jetson T4000 level: graphics clock locked at 1005 MHz (tensor compute about T4000) and memory locked at 5001 MHz (480 GB/s, faster than T4000) and at 810 MHz (78 GB/s, slower than T4000). The T4000 figure (273 GB/s) is interpolated between the two measured runs. Text in, text out through the page's own `think()`, no Cartesia. 31-turn console conversation in English, Hindi and Hinglish, with faults, procedures, timers, a call and a jump.

| Qwen3.8-27B FP8 | Question | Action (2 calls) | Average turn |
|---|---:|---:|---:|
| v80, no MTP, 480 GB/s | 3.5 s | 6.4 s | 5.3 s |
| v80, no MTP, 78 GB/s | 16.1 s | 32.2 s | 23.1 s |
| **v80, no MTP, T4000 estimate** | **5.4 s** | **10.2 s** | **7.9 s** |
| v84 + MTP, 480 GB/s | 2.6 s | 5.2 s | 3.9 s |
| v84 + MTP, 78 GB/s | 8.7 s | 17.8 s | 12.2 s |
| **v84 + MTP, T4000 estimate** | **3.5 s** | **7.0 s** | **5.1 s** |

Accuracy, built-in 27-task test run 3 times each: v78 without MTP 69/81, v78 with MTP 68/81 (within run-to-run noise; MTP verifies every drafted token with the full model). v84 sends the model a byte-identical request to v78, so its accuracy is v78's.

What each call costs: about 7,700 input tokens (tools 3,046, Arya instructions 844, mission context 1,759, Hindi rules 216, live snapshot 1,857, question about 17), plus the last 4 turns. vLLM reuses about 60 to 70 % of it from the previous call. On a T4000 the larger cost for Qwen FP8 is writing the answer (every output token reads all 28 GB of weights, about 10 tokens/s at 273 GB/s), which is what MTP addresses.

Tried and rejected, because accuracy dropped:

| Change | Speed at 480 GB/s | Accuracy |
|---|---|---|
| Live data moved into the crew's latest message (v81/v82) | average turn 3.9 → 2.6 s | two timed actions 2/8 (v78 7/8), asks before a call 4/8 (8/8), Hindi light command claimed done without the tool call 3/8 |
| Fixed rules first, live data at the end of the system prompt, two lookup tools removed (v83) | faster | 65/81 against v78's 68/81; made up an answer where it should say "not on the console" 2/3 |

Lesson: any change to the prompt's wording, order or tool list changes Qwen's behaviour and must pass the 27-task test three times against v78 before it ships. Server-side settings (MTP) did not.

Other measured points:

- Ternary Bonsai 2 27B (1.75-bit, 6 GB, PrismML llama.cpp fork): 22/27 against Qwen's 24/27 in one run; made up an answer on the "not on the console" trap; called the Flight Director without a yes; stuck in a tool loop on "what is the standard procedure". Slower than Qwen on a T4000 (about 6.6 s per question) because it re-reads the whole prompt every call.
- `--checkpoint-min-step 512` is needed for Bonsai in llama.cpp; the default 8192 is larger than Arya's prompt, so nothing was ever reused.
- SiMa Modalix (about 102 GB/s, 50 INT8 TOPS) was estimated far too slow for a 27B model with this prompt. Jetson T5000 has the same 273 GB/s as T4000 and about 1.7× the compute: answer writing is no faster, prompt reading is.

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
