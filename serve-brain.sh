#!/usr/bin/env bash
# Arya brain: Qwen3.8-27B, official FP8 checkpoint, on one GPU.
# OpenAI-compatible API at http://localhost:8000/v1 for index.html ("Local: vLLM").
# Tested 11 Nov 2026 on an RTX 6000 Ada (48 GB) with vLLM 0.28.0.
#
#   ./serve-brain.sh                      # GPU 0, offline (model already downloaded)
#   GPU=1 ./serve-brain.sh                # another GPU
#   VLLM=/path/to/venv/bin/vllm ./serve-brain.sh
#   HF_HUB_OFFLINE=0 ./serve-brain.sh     # first run: let vLLM download the model
#
# Download once beforehand (about 29 GB):  hf download Qwen/Qwen3.8-27B-FP8
set -u

VLLM="${VLLM:-vllm}"
MODEL="${LLM_MODEL:-Qwen/Qwen3.8-27B-FP8}"
CTX="${CTX:-32768}"                       # the page sends about 7,000 tokens per turn
ORIGINS="${ORIGINS:-[\"http://localhost:8080\",\"http://127.0.0.1:8080\"]}"
export CUDA_VISIBLE_DEVICES="${GPU:-${CUDA_VISIBLE_DEVICES:-0}}"

# Weights are local: do not contact Hugging Face at start. A CDN error there
# once made startup fail even though every file was on disk.
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"

# FlashInfer compiles kernels at start and needs nvcc (the CUDA toolkit).
# Where only the driver is installed, use vLLM's prebuilt flash attention.
export VLLM_ATTENTION_BACKEND="${VLLM_ATTENTION_BACKEND:-FLASH_ATTN}"
export VLLM_USE_FLASHINFER_SAMPLER="${VLLM_USE_FLASHINFER_SAMPLER:-0}"

echo "model   : $MODEL  (FP8 is read from the checkpoint: no --quantization flag)"
echo "gpu     : CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo "context : $CTX tokens"
echo "serving : http://localhost:8000/v1   allowed page origins: $ORIGINS"

# --max-num-seqs 16       : the default 256 exceeds this hybrid model's state
#                           cache on a 48 GB card and startup fails
# --language-model-only   : text brain only; skips the vision tower
# qwen3_coder / qwen3     : tool and reasoning parsers per the vLLM Qwen3.8 recipe
#                           (hermes is wrong for this model)
# enable_thinking false   : the page only switches thinking off for OpenRouter
# --allowed-origins       : the browser calls the server directly (CORS)
exec "$VLLM" serve "$MODEL" \
  --served-model-name "$MODEL" \
  --host 0.0.0.0 --port 8000 \
  --max-model-len "$CTX" \
  --gpu-memory-utilization "${GPU_UTIL:-0.90}" \
  --max-num-seqs 16 \
  --language-model-only \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --allowed-origins "$ORIGINS" \
  "$@"
