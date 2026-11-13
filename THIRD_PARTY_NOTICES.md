# Third-Party Notices

`push-to-dictate` bundles and depends on the following third-party components. Full license texts are in the `Licenses/` directory of this repository (committed) and inside `push-to-dictate.app/Contents/Resources/Licenses/` of the built application.

## whisper.cpp

- Project: https://github.com/ggerganov/whisper.cpp
- Pinned version: v1.7.2
- License: MIT License
- Copyright (c) 2023-2024 The ggml authors

Used for local speech-to-text inference. The compiled `whisper-cli` binary is shipped inside the application bundle; the source tree is fetched into `vendor/whisper.cpp/` via `scripts/setup.sh` and is not committed to this repository.

Full license text: `Licenses/whisper.cpp-LICENSE.txt`

## Whisper (model)

- Project: https://github.com/openai/whisper
- Model files used: `ggml-small.en.bin` (and optionally other `ggml-*.bin` sizes)
- License: MIT License
- Copyright (c) 2022 OpenAI

The `ggml-*.bin` files are format conversions of OpenAI's original Whisper model weights, redistributed by the whisper.cpp project under the same MIT license. Used as the speech-to-text model for the local backend.

Full license text: `Licenses/whisper-model-LICENSE.txt`
