# CUDA and OptiX on this driver

**Short answer:** this driver cannot provide CUDA or OptiX, and neither can be built from this repository. Both are
closed NVIDIA software that NVIDIA ships for Linux and Windows only. This page says what that means in practice, what
in this tree already touches NVIDIA's compiler stack, and what the workable paths are for software that wants GPU
compute or ray tracing on macOS through this driver.

## What CUDA and OptiX are made of

| Piece | Source | Shipped for macOS? |
|---|---|---|
| CUDA driver API (`libcuda`) | closed, part of NVIDIA's user-mode driver | last release CUDA 10.2 (2019), for the NVIDIA web driver on macOS 10.13 and Kepler to Pascal cards |
| CUDA runtime and libraries (`libcudart`, cuBLAS, cuDNN, cuFFT, NCCL, …) | closed, CUDA Toolkit | ended with 10.2 |
| `nvcc`, `ptxas` (PTX to SASS), `libnvvm` | closed, CUDA Toolkit | ended with 10.2; newer SM targets never |
| OptiX (`libnvoptix`, the `optix` headers) | closed; since OptiX 7 it lives inside the driver package | last macOS release OptiX 5.1 (2018) |
| RT core and tensor core programming | closed firmware and driver paths | never |
| GPU kernel driver: resource manager, GSP | open (`open-gpu-kernel-modules`, MIT/GPL) | **ported here: `kexts/NVRM`** |
| Unified memory (`nvidia-uvm`) | open (`open-gpu-kernel-modules`) | not ported here |

The kernel side of CUDA on Linux is the same open resource manager this driver runs under macOS. Everything above it
that an application links against is closed, built for the Linux and Windows ABIs, and for Turing and later cards was
never built for macOS at all. There is no source to port and no binary that would load, so "add CUDA support" has no
build-time meaning for this tree: no flag, patch or SDK turns it on.

## What this tree already does with NVIDIA's compiler stack

- **Native code generation.** NVK's NAK compiler turns SPIR-V into native SASS for the card, so Metal compute kernels
  already run as native NVIDIA machine code. Metal compute is the macOS counterpart of a CUDA kernel.
- **The vendor compiler lane** (`plugin/NVMTLVendorCompiler.m`). When `NVMTL_VENDOR_COMPILER` is set, the plugin
  hands Apple AIR to `NVIDIAShared.bundle`, which carries NVIDIA's NVVM libraries (the CUDA compiler back end) and an
  AIR-to-NVVM script. The reply holds PTX and a cubin. The plugin parses the cubin ELF (`.text.<kernel>`, the
  REGCOUNT and KPARAM_INFO entries of `.nv.info`, the parameter area of `.nv.constant0`) and dispatches the SASS through
  `nvmtl_nvk_dispatch_sass_v1`, an entry point `nvk/nvk-macos.patch` adds to NVK (`src/nouveau/vulkan/nvmtl_nvk_sass.c`).
  That hook uploads the code, fills constant bank 0 in CUDA's layout (shared and local windows, block and grid
  dimensions at 0x360 and 0x370, parameters at 0x380) and launches a QMD. Its limits: compute only, at most sixteen
  8-byte parameters, no local memory or call stack, no shared memory, no barriers, whole workgroups only, and a chip
  from the known table (TU1xx, GA10x, AD10x, GB10x, GB20x). `NVIDIAShared.bundle` is not in this repository; the
  release package carries it.
- So a CUDA-compiled kernel, a cubin, can be executed by this stack today, but only in that narrow shape, and
  nothing provides the CUDA API around it.

## What a CUDA driver on this stack would take

1. **The API surface.** The driver API alone is several hundred functions: contexts, modules, memory, streams,
   events, graphs, textures, interop. A runtime (`libcudart`) sits on top with its own ABI the toolkit's compiled
   programs expect.
2. **Kernel loading.** The cubin parsing above is a fragment: a real loader handles every `.nv.info` attribute, local
   memory (SLM), shared memory, barriers, relocations, constant banks beyond 0, texture and surface references,
   separate compilation and the per-SM QMD differences.
3. **PTX.** Toolkit programs ship PTX for forward compatibility and expect the driver to assemble it. There is no
   `ptxas` for macOS newer than CUDA 10.2, and that one stops at Turing. Cubins would have to be prebuilt on Linux
   for each SM, or produced by the NVVM libraries in `NVIDIAShared.bundle`, whose redistribution terms are NVIDIA's.
4. **Memory.** Managed and unified memory need the `nvidia-uvm` port that does not exist here; every CUDA program of
   consequence uses them through the libraries.
5. **The libraries.** cuBLAS, cuDNN, cuFFT, NPP and the rest are closed and Linux/Windows only. Blender's CUDA
   device, PyTorch, DaVinci Resolve and similar link them.

A research-grade path that launches hand-built cubins through the hook above is weeks of work and useful to almost
no application. A CUDA that runs shipping software is not achievable without NVIDIA producing it.

## OptiX

OptiX is implemented inside NVIDIA's closed driver on top of CUDA and the RT cores, loaded through `libnvoptix`.
There is no specification to reimplement and no macOS release past OptiX 5.1, which needed CUDA 10 and the web driver.
Nothing in this tree can supply it.

The macOS counterpart is **Metal ray tracing**: `MTLAccelerationStructure`, intersection functions and ray queries, and
`MPSRayIntersector`. This driver implements Metal ray tracing on NVK's acceleration structures (the patch's BVH
builder under `src/nouveau/vulkan/bvh/`, `nvk_acceleration_structure.c`, `nvk_nir_ray_tracing.c`), which is Vulkan ray
tracing on the card's hardware. Blender's Cycles has a Metal back end with MetalRT; whether it accepts this driver's
device is not qualified yet (see the scope note in [`RELEASE-1.1.0.md`](RELEASE-1.1.0.md)).

## What to use instead

The practical guide, with a probe that proves the card does Vulkan compute outside Metal and the build steps for
llama.cpp and friends on it, is [`CUDA-ALTERNATIVES.md`](CUDA-ALTERNATIVES.md). In short:

| You want | The macOS path | On this driver |
|---|---|---|
| Blender rendering | Cycles, Metal device (MetalRT for hardware ray tracing) | not qualified; a test target for the next releases |
| Machine learning | Core ML, PyTorch's MPS back end, TensorFlow with the Metal plugin | Core ML is listed as working; the plugin carries an MPS convolution fast path (`plugin/nvconv.metal`); the rest is not qualified |
| Video and image tools | Metal compute, Core Image, MPS | Core Image and MPS pass the release checks in [`CARD-SUPPORT.md`](CARD-SUPPORT.md) |
| Your own compute code | Metal Shading Language compute kernels; OpenCL through Apple's deprecated CL-on-Metal layer | the regular path through the translator and NVK |

## What this branch changed

The build was the other half of the request. The scripts under `build/` were tied to the original author's machine
(`~/nvmtl-build/LIVE`, `~/ogkm610`, `~/Vulkan-Headers`) and two of the four kexts had no recipe at all. The branch
makes every script build from this checkout with environment overrides, adds `build/build.sh` as the one entry point
that also states what the public tree cannot build (NVRM.kext's link inputs, the release-package files), adds
`nvk/prepare-mesa.sh` to fetch Mesa at `nvk/MESA_BASE` and apply the patch, gates the translator tests that read the unpublished fixture corpus (and the wrapper's tests over the author's
private captures) behind Cargo features so `cargo test` compiles and runs from a clean checkout (`translator/run_tests.sh` runs both
suites and fails only on failures outside `translator/known-failing-tests.txt`), and adds a GitHub Actions workflow that builds the translator,
the plugin, NVRMAGDC and the 1401 app on macOS runners, runs the repository's tests, and checks the NVK patch against
its Mesa base. None of that adds CUDA or OptiX, for the reasons above.
