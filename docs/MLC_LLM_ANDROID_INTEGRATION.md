# MLC LLM Android integration spike

Status: **research / build spike only**. This document deliberately does not claim that MLC LLM can compile or run LiquidAI LFM2.5-230M yet.

## Findings

CubicLM currently routes local inference through two existing engines:

- GGUF models use the vendored `llama_flutter_android` plugin and `llama.cpp`.
- `.litertlm` models use the existing LiteRT-LM plugin.

The native `llama.cpp` CMake configuration in `local_plugins/llama_flutter_android/android/CMakeLists.txt` explicitly sets `GGML_VULKAN OFF`; it does not enable OpenCL either. That explains why the current CubicLM GGUF native build is not configured for Vulkan. It is separate from the CPU-only `~/llama.cpp` build in Termux.

MLC's Android guide describes a host-side packaging workflow: configure models in `android/MLCChat/mlc-package-config.json`, run `mlc_llm package`, then include the generated `dist/lib/mlc4j` Gradle library in the Android app. The runtime/model code is compiled into native artifacts; embedding the MLC Chat APK itself is not the right integration approach.

MLC documents OpenCL support for Mali GPUs, but this does not establish that the runtime will initialize on every Mali device. CubicLM's target device (MediaTek MT6835 / Mali) still needs a physical-device test.

## Critical model compatibility gate

The target model is LiquidAI LFM2.5-230M Q4_K_M in GGUF format. MLC does not load that GGUF file directly: MLC needs supported Hugging Face model weights converted to MLC format plus a model library compiled for the target backend.

Before adding an MLC engine to CubicLM, prove all of the following in a standalone MLC build:

1. The exact LFM2.5-230M architecture/config is accepted by the selected MLC LLM revision.
2. Weight conversion and model-library compilation complete without architecture-specific patches.
3. The generated Android ARM64 runtime/model artifacts package successfully.
4. The model loads and generates correct output on a physical MT6835/Mali device.
5. A repeatable benchmark beats CubicLM's current 4.3 tokens/s baseline without unacceptable memory use, heat, or instability.

If architecture support is missing, create a **separate fork of `mlc-ai/mlc-llm` only when a concrete compiler/model implementation patch is required**. Keep that fork pinned to an upstream commit and carry a small, documented patch set. Do not fork MLC Chat just to add a model: its Android app is a demo shell, while the reusable component for CubicLM is the generated `mlc4j` runtime plus model library.

## Recommended integration architecture

1. Keep the current GGUF and LiteRT engines unchanged.
2. Build and validate MLC artifacts in a separate host-side workspace/CI job.
3. Add an isolated Android Flutter plugin (for example, `local_plugins/mlc_flutter_android`) that wraps the MLC Android Java API using a MethodChannel/EventChannel or Pigeon. Map load, streaming generation, stop, and dispose into CubicLM's existing engine contract.
4. Add a runtime identifier such as `mlc` only after the plugin can load a verified model. Do not infer MLC from `.gguf`; keep MLC-converted model directories/configs distinct from GGUF.
5. Add a settings toggle only after successful initialization can be detected and reported accurately. Keep CPU/GGUF fallback intact.
6. Benchmark on the target phone and add regression tests before enabling it in release builds.

## Host build prerequisites

Follow the official MLC Android SDK documentation for the exact pinned MLC revision. The documented build requires the MLC repository and recursive submodules, an installed `mlc_llm` Python package, Rust/Cargo, JDK, Android SDK/NDK, CMake, and Ninja. Keep the compiler environment isolated (for example, in a dedicated Conda environment); do not install the MLC compiler dependencies into the Android app or Termux's existing llama.cpp build.

Official references:

- Android SDK/build and packaging: https://llm.mlc.ai/docs/deploy/android.html
- Model conversion/compilation: https://llm.mlc.ai/docs/compilation/compile_models.html
- MLC LLM source: https://github.com/mlc-ai/mlc-llm

## Current status of this branch

This spike adds documentation and a guarded packaging helper only. It does **not** add the MLC runtime to CubicLM, change the active inference engine, or claim LFM2.5 support. Those changes would be premature until the compatibility gate above passes.


## GitHub Actions build

The branch now includes `.github/workflows/mlc-android.yml`. It builds the official MLC Chat Android app and its generated ARM64 `mlc4j` runtime on a Linux GitHub Actions runner. The workflow uses the official MLC nightly CPU compiler package on the host, Android NDK 27.0.11718014, JDK 17, and the selected MLC source revision.

- The default smoke-test model is `mlc-ai/Qwen2.5-0.5B-Instruct-q4f16_1-MLC`, a pre-converted MLC model with a supported Qwen2 architecture. It is deliberately small for the 4 GB target device.
- Model weights are not bundled in the APK; MLC Chat downloads them when selected.
- Outputs are uploaded as a GitHub Actions artifact: `MLCChat-arm64-debug.apk`, `mlc4j-arm64-runtime.tar.gz`, and build provenance.
- The workflow can also be manually dispatched with a different pre-converted MLC Hugging Face model and MLC source ref.
- This is a standalone MLC Chat validation APK, not yet a CubicLM-integrated runtime plugin.
- The default build is an ARM64 package. Actual Mali/OpenCL acceleration, memory use, stability, and throughput still require testing on the physical Moto G 2025.

To run it manually, open **Actions → MLC Android ARM64 package → Run workflow** on this branch. Download the artifact named `mlc-android-arm64-<run number>` after the job succeeds.

The user's existing LFM2.5-230M GGUF remains a separate compatibility gate. Do not pass that GGUF directly to this workflow: MLC requires a model converted to its own format, and LFM2.5 architecture support has not yet been verified.
