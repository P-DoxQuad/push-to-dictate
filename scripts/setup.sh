#!/usr/bin/env bash
#
# setup.sh — populate vendor/ with whisper.cpp source, built binary, and model.
# Idempotent: re-running skips any step whose output already exists.
#
# Required tools in PATH (or /opt/local/bin via MacPorts):
#   git, cmake, curl, shasum
#
set -euo pipefail

# --- Config -----------------------------------------------------------------

# Whisper.cpp upstream and pinned revision.
# Flip WHISPER_REPO to your own fork once created; v1.7.2 is the last tag
# before whisper.cpp requires C++17 <filesystem> (unavailable on macOS 10.13
# with Xcode 10.1).
WHISPER_REPO="${WHISPER_REPO:-https://github.com/ggerganov/whisper.cpp}"
WHISPER_COMMIT="${WHISPER_COMMIT:-v1.7.2}"

# Model: Hugging Face is the default source; flip MODEL_URL to a GitHub
# Release asset URL on this repo once you've uploaded a preservation copy.
MODEL_URL="${MODEL_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin}"
MODEL_FILENAME="ggml-small.en.bin"
MODEL_SHA256="c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d"

# CMake flags required for Mac Pro 5,1 class Xeons (Westmere / Nehalem):
# AVX / AVX2 / FMA / F16C are not supported — default whisper.cpp builds will
# die with "illegal instruction" at launch without disabling them.
CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DGGML_METAL=OFF
    -DGGML_AVX=OFF
    -DGGML_AVX2=OFF
    -DGGML_FMA=OFF
    -DGGML_F16C=OFF
    -DGGML_NATIVE=ON
)

# --- Locate repo root -------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
WHISPER_DIR="${VENDOR_DIR}/whisper.cpp"
MODELS_DIR="${VENDOR_DIR}/models"
MODEL_PATH="${MODELS_DIR}/${MODEL_FILENAME}"

# --- Locate cmake -----------------------------------------------------------

if command -v cmake >/dev/null 2>&1; then
    CMAKE="cmake"
elif [ -x /opt/local/bin/cmake ]; then
    CMAKE="/opt/local/bin/cmake"
else
    echo "error: cmake not found. Install via MacPorts: sudo port install cmake" >&2
    exit 1
fi

# --- Clone whisper.cpp ------------------------------------------------------

if [ ! -d "${WHISPER_DIR}/.git" ]; then
    echo "==> Cloning ${WHISPER_REPO} into vendor/whisper.cpp/"
    mkdir -p "${VENDOR_DIR}"
    git clone "${WHISPER_REPO}" "${WHISPER_DIR}"
    git -C "${WHISPER_DIR}" checkout "${WHISPER_COMMIT}"
else
    current="$(git -C "${WHISPER_DIR}" rev-parse HEAD)"
    desired="$(git -C "${WHISPER_DIR}" rev-parse "${WHISPER_COMMIT}" 2>/dev/null || echo "")"
    if [ -n "${desired}" ] && [ "${current}" != "${desired}" ]; then
        echo "==> Checking out ${WHISPER_COMMIT} in vendor/whisper.cpp/"
        git -C "${WHISPER_DIR}" checkout "${WHISPER_COMMIT}"
    else
        echo "==> vendor/whisper.cpp/ already at ${WHISPER_COMMIT}"
    fi
fi

# --- Build whisper.cpp ------------------------------------------------------

# v1.7.2 builds the CLI as `main`; we expose it as `whisper-cli` to match the
# modern upstream name that the app looks for in its Resources.
BUILT_MAIN="${WHISPER_DIR}/build/bin/main"
BUILT_CLI="${WHISPER_DIR}/build/bin/whisper-cli"

if [ ! -x "${BUILT_MAIN}" ]; then
    echo "==> Configuring whisper.cpp with no-AVX flags"
    "${CMAKE}" -S "${WHISPER_DIR}" -B "${WHISPER_DIR}/build" "${CMAKE_FLAGS[@]}"
    echo "==> Building whisper.cpp (this takes a few minutes)"
    "${CMAKE}" --build "${WHISPER_DIR}/build" -j 6 --config Release
else
    echo "==> whisper.cpp binary already built at ${BUILT_MAIN}"
fi

if [ ! -x "${BUILT_CLI}" ] || [ "${BUILT_MAIN}" -nt "${BUILT_CLI}" ]; then
    echo "==> Copying main -> whisper-cli"
    cp "${BUILT_MAIN}" "${BUILT_CLI}"
fi

if ! "${BUILT_CLI}" --help >/dev/null 2>&1; then
    echo "error: ${BUILT_CLI} failed its --help smoke test" >&2
    exit 1
fi

# --- Download model ---------------------------------------------------------

verify_model() {
    local actual
    actual="$(shasum -a 256 "${MODEL_PATH}" | awk '{print $1}')"
    if [ "${actual}" != "${MODEL_SHA256}" ]; then
        echo "error: ${MODEL_FILENAME} SHA256 mismatch" >&2
        echo "  expected: ${MODEL_SHA256}" >&2
        echo "  actual:   ${actual}" >&2
        return 1
    fi
    return 0
}

mkdir -p "${MODELS_DIR}"

if [ -f "${MODEL_PATH}" ]; then
    if verify_model; then
        echo "==> Model already present and SHA256 verified"
    else
        echo "==> Model present but SHA256 mismatch — re-downloading"
        rm -f "${MODEL_PATH}"
    fi
fi

if [ ! -f "${MODEL_PATH}" ]; then
    echo "==> Downloading ${MODEL_FILENAME} from ${MODEL_URL}"
    curl -L --progress-bar -o "${MODEL_PATH}" "${MODEL_URL}"
    verify_model
fi

echo ""
echo "==> Setup complete."
echo "    whisper-cli: ${BUILT_CLI}"
echo "    model:       ${MODEL_PATH}"
