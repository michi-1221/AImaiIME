#!/bin/bash
# 外部依存を取得する（バージョンとハッシュは固定）。
#   - llama.cpp のビルド済み XCFramework（Metal 入り）→ vendor/llama.xcframework
#   - 動作確認用の zenz-v3.1-small（GGUF）→ models/  ※ --with-test-model のときだけ
# 取得物は ime/.gitignore で無視される。
# すでに取得済みのものも、タグとハッシュを毎回検証する。ハッシュが一致しないファイルは消して止まる。
set -euo pipefail

cd "$(dirname "$0")/.."

LLAMA_TAG="b12193"
LLAMA_ZIP="llama-${LLAMA_TAG}-xcframework.zip"
LLAMA_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/${LLAMA_ZIP}"
LLAMA_SHA256="660d5864adc21ec0d619d30424d03a9478d17fc345cc2d5615d22a8c259e0eaf"

ZENZ_REV="ddf6e44b2e05ab7ea9a3e31559c5e7948761365c"
ZENZ_URL="https://huggingface.co/Miwa-Keita/zenz-v3.1-small-gguf/resolve/${ZENZ_REV}/ggml-model-Q5_K_M.gguf"
ZENZ_FILE="models/zenz-v3.1-small-Q5_K_M.gguf"
ZENZ_SHA256="4de930c06bef8c263aa1aa40684af206db4ce1b96375b3b8ed0ea508e0b14f6c"

# ハッシュを検証する。一致しなければファイルを消して終了する。
verify_or_delete() { # file expected
  local got
  got=$(shasum -a 256 "$1" | awk '{print $1}')
  if [ "$got" != "$2" ]; then
    echo "SHA256 が一致しないため削除しました: $1 ($got != $2)" >&2
    rm -f "$1"
    exit 1
  fi
}

mkdir -p vendor models

# --- llama.cpp ---
STAMP="vendor/llama.xcframework.version"
EXPECTED_STAMP="${LLAMA_TAG} ${LLAMA_SHA256}"

if [ ! -f "vendor/${LLAMA_ZIP}" ]; then
  echo "llama.cpp ${LLAMA_TAG} の XCFramework を取得します"
  curl -fL -o "vendor/${LLAMA_ZIP}.part" "$LLAMA_URL"
  mv "vendor/${LLAMA_ZIP}.part" "vendor/${LLAMA_ZIP}"
fi
verify_or_delete "vendor/${LLAMA_ZIP}" "$LLAMA_SHA256"

# 展開済みのものが、このタグ・ハッシュの zip から作られたものでなければ作り直す
if [ ! -d vendor/llama.xcframework ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$EXPECTED_STAMP" ]; then
  echo "vendor/llama.xcframework を ${LLAMA_ZIP} から展開します"
  rm -rf vendor/llama.xcframework vendor/_unzip "$STAMP"
  mkdir vendor/_unzip
  unzip -q "vendor/${LLAMA_ZIP}" -d vendor/_unzip
  xcf=$(find vendor/_unzip -maxdepth 3 -name 'llama.xcframework' -type d | head -1)
  if [ -z "$xcf" ]; then
    echo "zip の中に llama.xcframework がありません" >&2
    rm -rf vendor/_unzip
    exit 1
  fi
  mv "$xcf" vendor/llama.xcframework
  rm -rf vendor/_unzip
  echo "$EXPECTED_STAMP" > "$STAMP"
fi

# --- テスト用モデル ---
if [ "${1:-}" = "--with-test-model" ]; then
  if [ ! -f "$ZENZ_FILE" ]; then
    echo "zenz-v3.1-small (GGUF Q5_K_M) を取得します"
    curl -fL -o "${ZENZ_FILE}.part" "$ZENZ_URL"
    mv "${ZENZ_FILE}.part" "$ZENZ_FILE"
  fi
  verify_or_delete "$ZENZ_FILE" "$ZENZ_SHA256"
fi

echo "完了（llama.cpp ${LLAMA_TAG}）"
