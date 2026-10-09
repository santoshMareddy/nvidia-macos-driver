# CUDA-class work on the NVIDIA card under this driver

CUDA itself cannot run here, for the reasons in [`CUDA-AND-OPTIX.md`](CUDA-AND-OPTIX.md). What the card *is* under this
driver: a Vulkan 1.3+ compute device through NVK, Mesa's open Vulkan driver, which the package installs with the Khronos
loader; and a Metal 3 device through the plugin. Vulkan compute is the open counterpart of CUDA kernels on NVIDIA
hardware, and a growing share of the software people reach for CUDA for has a Vulkan back end. This page is the
practical guide: how to prove the card does compute outside Metal, how to point software at it, which path fits which
workload, and where the limits are.

## 1. Prove the card does compute outside Metal

`nvk-compute-check` is a small Vulkan program in `tools/nvk-compute-check/`. It loads the driver's own loader and ICD
manifest, lists the devices the loader sees, picks the NVIDIA one, prints what it offers to compute work, runs saxpy
over a million floats and checks every result on the CPU.

```bash
build/build_compute_check.sh            # macOS with Xcode and ~/Vulkan-Headers; CI also publishes the binary
out/compute-check/nvk-compute-check     # no arguments: uses /Library/GPUBundles/nvmtl/{libvulkan.dylib,nvk_icd.json}
```

Expected shape of the output (this one is from Mesa's software device, which CI runs it on):

```
devices: 1
  [0] NVIDIA GeForce RTX 5060 (NVK GB206)  (discrete GPU, vendor 0x10de ..., Vulkan 1.4, driver NVK Mesa 26.3...)
compute: workgroup up to 1024 invocations ..., 48 KiB shared memory, 65535 groups per dispatch axis
subgroup: 32 lanes; operations: arithmetic ballot shuffle clustered quad
types: int64 yes, float64 yes, int16 yes, float16 yes, int8 yes; 16-bit storage yes, 8-bit storage yes
memory model: buffer device address yes, Vulkan memory model yes, timeline semaphores yes
extensions: +KHR_cooperative_matrix ... +KHR_ray_query ...
memory: 8.0 GiB device-local, ... host-visible heaps
saxpy: 1048576 elements, 3 runs, best 0.4 ms (... GiB/s through host-visible memory), 0 wrong
PASS: Vulkan compute runs on NVIDIA GeForce RTX 5060 (NVK GB206) through NVK ...
```

`FAIL: cannot load the Vulkan loader` means the driver package is not installed. `the loader found no Vulkan device`
means the ICD manifest did not load NVK: run with `VK_LOADER_DEBUG=all` to see why. A wrong-result count or a timeout
is a driver problem worth a report through 1401's Send logs.

## 2. Point Vulkan software at NVK

```bash
. tools/nvk-env.sh        # VK_ICD_FILENAMES and VK_DRIVER_FILES -> /Library/GPUBundles/nvmtl/nvk_icd.json
```

The Khronos loader honours these in every process, including a loader an application ships itself or the Vulkan SDK's;
a program built against MoltenVK's loader still ends up on NVK when the variables are set. `vulkaninfo --summary` from
the Vulkan SDK is a second, independent check. The plugin sets two more knobs before it loads NVK for Metal work:
`NVRM_FLUSH_TIMEOUT_MS` and `MESA_SHADER_CACHE_DIR` (see `plugin/nvmtl_vk.c`); a standalone Vulkan process uses NVK's
defaults for both, which is fine for the probe, and the shader cache lands in `~/.cache/mesa_shader_cache`.

## 3. Which path for which workload

| You want | The CUDA way | On this card | State |
|---|---|---|---|
| LLM inference | llama.cpp with CUDA | llama.cpp's Vulkan back end on NVK (section 4) | NVK runs it on Linux; on this driver, not yet tried: it is the first thing to try |
| Speech to text | whisper.cpp with CUDA | whisper.cpp's Vulkan back end on NVK (same build switch) | same |
| Image generation | PyTorch with CUDA | stable-diffusion.cpp's Vulkan back end on NVK; or PyTorch's MPS device through the Metal plugin | not qualified |
| ML frameworks | PyTorch, JAX with CUDA | PyTorch MPS and Core ML through the plugin; Burn or Candle through wgpu's Vulkan back end on NVK | not qualified |
| Rendering | Blender Cycles with CUDA or OptiX | Cycles' Metal device through the plugin; MetalRT is Metal ray tracing on NVK's acceleration structures | not qualified ([`RELEASE-1.1.0.md`](RELEASE-1.1.0.md)) |
| Video | DaVinci Resolve with CUDA | its Metal path through the plugin | not qualified |
| FFT, BLAS, image processing | cuFFT, cuBLAS, NPP | VkFFT (Vulkan 1.1+), Vulkan or Metal compute kernels, MPS | VkFFT runs on any Vulkan device |
| Your own kernels | CUDA C++ | GLSL, HLSL, Slang or WGSL compute to SPIR-V on NVK; Metal Shading Language through the plugin; rust-gpu | the regular path |
| Unmodified CUDA software | | Linux on the same machine with NVIDIA's driver (dual boot), the only place `libcuda` runs on Turing and later | |

"Not qualified" means the release checks in [`CARD-SUPPORT.md`](CARD-SUPPORT.md) do not cover it, not that it fails.

## 4. LLM inference: llama.cpp on NVK

llama.cpp's Vulkan back end needs the Vulkan headers, a loader to link against and `glslc` at build time. The driver's
loader works at run time through the environment above; the build can link Homebrew's.

```bash
brew install cmake glslang shaderc vulkan-headers vulkan-loader
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
cmake -B build -DGGML_VULKAN=ON -DGGML_METAL=OFF -DCMAKE_OSX_ARCHITECTURES=x86_64
cmake --build build --config Release -j
. /path/to/nvidia-macos-driver/tools/nvk-env.sh
./build/bin/llama-cli -m model.gguf -ngl 99 -p "Hello"      # -ngl 99: every layer on the GPU
```

What to expect: `ggml_vulkan: Found 1 Vulkan devices: ... NVIDIA ... (NVK ...)` at start. Speed depends on what NVK
exposes: the probe's `+KHR_cooperative_matrix` line means the matrix-multiply fast path is available on this card
and Mesa version, `float16 yes` the half-precision one. The Vulkan back end is slower than CUDA on the same card,
and NVK is younger than NVIDIA's own driver; a crash or a hang is a report, not a configuration error on your side.
`whisper.cpp` and `stable-diffusion.cpp` build the same way with their `GGML_VULKAN` / `SD_VULKAN` switches.

## 5. CUDA source code

There is no drop-in way to run CUDA C++ on this stack:

- **ZLUDA** (CUDA on other GPUs) compiles PTX for AMD through ROCm; it has no Vulkan or NVK back end.
- **chipStar** (CUDA and HIP through SPIR-V) needs an OpenCL or Level Zero runtime that accepts kernel-dialect
  SPIR-V; neither exists on this stack. Apple's OpenCL is CL 1.2 on Metal and takes no SPIR-V.
- **The vendor compiler lane** in the plugin can execute a cubin's SASS in a narrow shape (no shared memory, no
  barriers, no local memory, at most sixteen parameters), is off by default and has no public API: it is a lab bench,
  not a CUDA runtime.

Porting is the path: a CUDA kernel is a compute shader with a different spelling. Thread index, block and grid map to
`gl_GlobalInvocationID`, `gl_WorkGroupID` and `gl_NumWorkGroups`; `__shared__` to `shared`; `__syncthreads()` to
`barrier()`; warp shuffles and votes to the subgroup operations the probe lists; device pointers to buffer device
addresses, which NVK supports. Slang compiles a CUDA-like language to SPIR-V and Metal both.

## 6. Limits to know

- Standalone Vulkan on this driver is the same NVK the Metal plugin uses, but the plugin's process setup, resource
  limits and recovery paths were qualified for Metal apps, not for a headless Vulkan process. Expect rough edges.
- Device-local memory is the card's VRAM through NVK's heaps; host-visible memory is system memory the GPU reads over
  PCIe. Keep model weights device-local (llama.cpp does).
- A GPU fault from a Vulkan process can take WindowServer's work with it. Save your work first.
