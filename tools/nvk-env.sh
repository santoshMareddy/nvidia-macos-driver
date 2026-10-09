# shellcheck shell=sh
# Point any Vulkan program at the NVIDIA card through NVK, the Vulkan driver this package installs:
#     . tools/nvk-env.sh
# The Khronos loader honours these in every process that uses it, including loaders an application ships itself.
export VK_ICD_FILENAMES=/Library/GPUBundles/nvmtl/nvk_icd.json
export VK_DRIVER_FILES=$VK_ICD_FILENAMES
export NVK_VULKAN_LOADER=/Library/GPUBundles/nvmtl/libvulkan.dylib
[ -f "$VK_ICD_FILENAMES" ] || echo "nvk-env: $VK_ICD_FILENAMES is missing; is the driver installed?" >&2
