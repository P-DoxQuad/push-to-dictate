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

# Whisper.cpp source. Points at a preservation fork of ggerganov/whisper.cpp
# pinned at v1.7.2 (the last tag before whisper.cpp requires C++17 <filesystem>,
# which is unavailable on macOS 10.13 with Xcode 10.1).
WHISPER_REPO="${WHISPER_REPO:-https://github.com/P-DoxQuad/whisper.cpp}"
WHISPER_COMMIT="${WHISPER_COMMIT:-v1.7.2}"

# Models bundled inside the .app at build time. Served from the project's own
# GitHub Release asset tag, independent of Hugging Face uptime. The tag name
# "openai-models-v1" refers to the origin of the Whisper weights (OpenAI's
# open-source speech model), not the OpenAI cloud backend the app can call
# into. These are local ggml-quantized files consumed by whisper-cli; they
# have no network component. Future backends with different model families
# will be namespaced under their own tags (e.g. meta-models-v1).
MODEL_BASE_URL="${MODEL_BASE_URL:-https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1}"

# Space-separated "filename:sha256" pairs. Empty sha256 skips verification for
# that entry. Hashes will be filled in once preservation copies are hosted.
BUNDLED_MODELS=(
    "ggml-tiny.en-q8_0.bin:"
    "ggml-base.en-q8_0.bin:"
)

# CMake flags for Mac Pro 5,1 class Xeons (Westmere) and earlier Nehalem CPUs.
# AVX / AVX2 / FMA / F16C are not supported; default whisper.cpp builds die
# with "illegal instruction" at launch without disabling them.
#
# Targeting Nehalem explicitly (instead of GGML_NATIVE=ON) emits code that
# runs unchanged on Westmere (Nehalem + AES-NI + PCLMULQDQ, neither of which
# whisper uses) while also running on first-generation Nehalem CPUs.
#
# CMAKE_OSX_DEPLOYMENT_TARGET=10.11 ensures the binary links against symbols
# available on El Capitan and newer.
CMAKE_FLAGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.11
    -DCMAKE_C_FLAGS=-march=nehalem
    -DCMAKE_CXX_FLAGS=-march=nehalem
    -DGGML_METAL=OFF
    -DGGML_AVX=OFF
    -DGGML_AVX2=OFF
    -DGGML_FMA=OFF
    -DGGML_F16C=OFF
    -DGGML_NATIVE=OFF
)

# --- Locate repo root -------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/vendor"
WHISPER_DIR="${VENDOR_DIR}/whisper.cpp"
MODELS_DIR="${VENDOR_DIR}/models"

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

# --- Download bundled models ------------------------------------------------

verify_model() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "${path}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        echo "error: $(basename "${path}") SHA256 mismatch" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        return 1
    fi
    return 0
}

mkdir -p "${MODELS_DIR}"

for entry in "${BUNDLED_MODELS[@]}"; do
    filename="${entry%%:*}"
    sha256="${entry#*:}"
    path="${MODELS_DIR}/${filename}"
    url="${MODEL_BASE_URL}/${filename}"

    if [ -f "${path}" ]; then
        if [ -n "${sha256}" ]; then
            if verify_model "${path}" "${sha256}"; then
                echo "==> ${filename} already present and SHA256 verified"
                continue
            else
                echo "==> ${filename} present but SHA256 mismatch, re-downloading"
                rm -f "${path}"
            fi
        else
            echo "==> ${filename} already present (no hash pinned, skipping verify)"
            continue
        fi
    fi

    echo "==> Downloading ${filename} from ${url}"
    curl -L --progress-bar -o "${path}" "${url}"
    if [ -n "${sha256}" ]; then
        verify_model "${path}" "${sha256}"
    fi
done

echo ""
echo "==> Setup complete."
echo "    whisper-cli: ${BUILT_CLI}"
echo "    models:      ${MODELS_DIR}/"
