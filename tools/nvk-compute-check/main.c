/*
 * nvk-compute-check: run a Vulkan compute kernel on the NVIDIA card through NVK's ICD, outside Metal, and verify it.
 *
 * The driver installs Mesa's NVK (Vulkan) under /Library/GPUBundles/nvmtl together with the Khronos loader and an ICD
 * manifest. Any Vulkan program can use that device directly; this one proves it: it enumerates the devices the loader
 * sees, picks the NVIDIA one, prints what it offers to compute work (limits, subgroup, integer and float widths,
 * device addresses, cooperative matrices, ray queries, memory), runs saxpy over a million floats and checks every
 * result on the CPU.
 *
 *   nvk-compute-check [--any-device] [--loader PATH] [--n COUNT]
 *
 * Environment: VK_ICD_FILENAMES / VK_DRIVER_FILES select the ICD (set to the driver's NVK manifest by default on
 * macOS); NVK_VULKAN_LOADER names the loader library (default: the driver's loader on macOS, libvulkan.so.1 elsewhere).
 * The binary links no Vulkan library: it dlopen()s the loader, so it builds with the Vulkan headers alone.
 *
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "kernel_spv.h"

#ifdef __APPLE__
#define DEFAULT_LOADER "/Library/GPUBundles/nvmtl/libvulkan.dylib"
#define DEFAULT_ICD    "/Library/GPUBundles/nvmtl/nvk_icd.json"
#else
#define DEFAULT_LOADER "libvulkan.so.1"
#define DEFAULT_ICD    ""          /* the loader's own search: /usr/share/vulkan/icd.d and friends */
#endif

#define FN_LIST(X) \
    X(vkEnumerateInstanceVersion) X(vkCreateInstance) X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) \
    X(vkGetPhysicalDeviceProperties2) X(vkGetPhysicalDeviceFeatures2) X(vkGetPhysicalDeviceQueueFamilyProperties) \
    X(vkGetPhysicalDeviceMemoryProperties) X(vkEnumerateDeviceExtensionProperties) X(vkCreateDevice) \
    X(vkGetDeviceQueue) X(vkCreateBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkBindBufferMemory) \
    X(vkMapMemory) X(vkUnmapMemory) X(vkCreateShaderModule) X(vkCreateDescriptorSetLayout) X(vkCreatePipelineLayout) \
    X(vkCreateComputePipelines) X(vkCreateDescriptorPool) X(vkAllocateDescriptorSets) X(vkUpdateDescriptorSets) \
    X(vkCreateCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkCmdBindPipeline) \
    X(vkCmdBindDescriptorSets) X(vkCmdPushConstants) X(vkCmdDispatch) X(vkCmdPipelineBarrier) X(vkEndCommandBuffer) \
    X(vkCreateFence) X(vkResetFences) X(vkQueueSubmit) X(vkWaitForFences) X(vkDeviceWaitIdle) X(vkDestroyFence) \
    X(vkDestroyCommandPool) X(vkDestroyDescriptorPool) X(vkDestroyPipeline) X(vkDestroyPipelineLayout) \
    X(vkDestroyDescriptorSetLayout) X(vkDestroyShaderModule) X(vkDestroyBuffer) X(vkFreeMemory) X(vkDestroyDevice)

#define DECLARE(n) static PFN_##n n;
FN_LIST(DECLARE)
#undef DECLARE
static PFN_vkGetInstanceProcAddr gipa;

static void die(const char *what, VkResult r) {
    if (r == VK_SUCCESS) fprintf(stderr, "FAIL: %s\n", what);
    else fprintf(stderr, "FAIL: %s (VkResult %d)\n", what, (int)r);
    exit(1);
}
#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) die(#call, r_); } while (0)

static void load(VkInstance inst) {
#define LOAD(n) n = (PFN_##n)gipa(inst, #n); if (!n && inst) die("the loader has no " #n, VK_SUCCESS);
    FN_LIST(LOAD)
#undef LOAD
}

static const char *device_type(VkPhysicalDeviceType t) {
    switch (t) {
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU: return "discrete GPU";
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU: return "integrated GPU";
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU: return "virtual GPU";
    case VK_PHYSICAL_DEVICE_TYPE_CPU: return "CPU";
    default: return "other";
    }
}

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int has_ext(const VkExtensionProperties *e, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++) if (strcmp(e[i].extensionName, name) == 0) return 1;
    return 0;
}

static uint32_t memory_type(const VkPhysicalDeviceMemoryProperties *mp, uint32_t bits, VkMemoryPropertyFlags want) {
    for (uint32_t i = 0; i < mp->memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp->memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

int main(int argc, char **argv) {
    int any_device = 0; const char *loader = getenv("NVK_VULKAN_LOADER"); uint32_t n = 1u << 20;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--any-device") == 0) any_device = 1;
        else if (strcmp(argv[i], "--loader") == 0 && i + 1 < argc) loader = argv[++i];
        else if (strcmp(argv[i], "--n") == 0 && i + 1 < argc) n = (uint32_t)strtoul(argv[++i], NULL, 10);
        else { fprintf(stderr, "usage: nvk-compute-check [--any-device] [--loader PATH] [--n COUNT]\n"); return 2; }
    }
    if (!loader || !*loader) loader = DEFAULT_LOADER;
    setvbuf(stdout, NULL, _IOLBF, 0);   /* keep stdout and the FAIL lines on stderr in order when piped */
    static const char default_icd[] = DEFAULT_ICD;
    if (default_icd[0] && !getenv("VK_ICD_FILENAMES") && !getenv("VK_DRIVER_FILES")) {
        FILE *f = fopen(default_icd, "r");
        if (f) { fclose(f); setenv("VK_ICD_FILENAMES", default_icd, 1); setenv("VK_DRIVER_FILES", default_icd, 1); }
    }
    printf("loader: %s\nicd:    %s\n", loader, getenv("VK_DRIVER_FILES") ? getenv("VK_DRIVER_FILES")
           : getenv("VK_ICD_FILENAMES") ? getenv("VK_ICD_FILENAMES") : "(loader default search)");

    void *lib = dlopen(loader, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "FAIL: cannot load the Vulkan loader %s: %s\n", loader, dlerror()); return 1; }
    gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    if (!gipa) die("the loader exports no vkGetInstanceProcAddr", VK_SUCCESS);
    load(VK_NULL_HANDLE);
    uint32_t loader_version = VK_API_VERSION_1_0;
    if (vkEnumerateInstanceVersion) vkEnumerateInstanceVersion(&loader_version);
    printf("loader Vulkan %u.%u.%u\n", VK_API_VERSION_MAJOR(loader_version), VK_API_VERSION_MINOR(loader_version),
           VK_API_VERSION_PATCH(loader_version));
    if (loader_version < VK_API_VERSION_1_2) die("the loader is older than Vulkan 1.2", VK_SUCCESS);

    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "nvk-compute-check",
                              .apiVersion = VK_API_VERSION_1_2 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    load(inst);

    uint32_t count = 0;
    CHECK(vkEnumeratePhysicalDevices(inst, &count, NULL));
    if (count == 0) die("the loader found no Vulkan device (is the ICD manifest right?)", VK_SUCCESS);
    VkPhysicalDevice *devs = calloc(count, sizeof *devs);
    CHECK(vkEnumeratePhysicalDevices(inst, &count, devs));
    VkPhysicalDevice pd = VK_NULL_HANDLE; VkPhysicalDeviceProperties2 props = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
    VkPhysicalDeviceDriverProperties drv = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
    VkPhysicalDeviceSubgroupProperties sub = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES };
    printf("devices: %u\n", count);
    for (uint32_t i = 0; i < count; i++) {
        VkPhysicalDeviceProperties2 p = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 };
        VkPhysicalDeviceDriverProperties d = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES };
        VkPhysicalDeviceSubgroupProperties s = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SUBGROUP_PROPERTIES, .pNext = &d };
        p.pNext = &s;
        vkGetPhysicalDeviceProperties2(devs[i], &p);
        printf("  [%u] %s  (%s, vendor 0x%04x device 0x%04x, Vulkan %u.%u, driver %s %s)\n", i, p.properties.deviceName,
               device_type(p.properties.deviceType), p.properties.vendorID, p.properties.deviceID,
               VK_API_VERSION_MAJOR(p.properties.apiVersion), VK_API_VERSION_MINOR(p.properties.apiVersion),
               d.driverName, d.driverInfo);
        int pick = any_device ? (pd == VK_NULL_HANDLE) : (p.properties.vendorID == 0x10DE && pd == VK_NULL_HANDLE);
        if (pick) { pd = devs[i]; props = p; drv = d; sub = s; }
    }
    if (pd == VK_NULL_HANDLE) die("no NVIDIA device (vendor 0x10DE) among them; --any-device takes the first one", VK_SUCCESS);
    printf("using: %s\n", props.properties.deviceName);

    VkPhysicalDeviceVulkan12Features f12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    VkPhysicalDeviceVulkan11Features f11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES, .pNext = &f12 };
    VkPhysicalDeviceFeatures2 feat = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f11 };
    vkGetPhysicalDeviceFeatures2(pd, &feat);
    uint32_t next = 0;
    CHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &next, NULL));
    VkExtensionProperties *ext = calloc(next, sizeof *ext);
    CHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &next, ext));
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    uint64_t vram = 0, host = 0;
    for (uint32_t i = 0; i < mp.memoryHeapCount; i++)
        if (mp.memoryHeaps[i].flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) vram += mp.memoryHeaps[i].size; else host += mp.memoryHeaps[i].size;
    const VkPhysicalDeviceLimits *lim = &props.properties.limits;
    printf("compute: workgroup up to %u invocations (%u x %u x %u), %u KiB shared memory, %u groups per dispatch axis\n",
           lim->maxComputeWorkGroupInvocations, lim->maxComputeWorkGroupSize[0], lim->maxComputeWorkGroupSize[1],
           lim->maxComputeWorkGroupSize[2], lim->maxComputeSharedMemorySize / 1024, lim->maxComputeWorkGroupCount[0]);
    printf("subgroup: %u lanes; operations:%s%s%s%s%s\n", sub.subgroupSize,
           sub.supportedOperations & VK_SUBGROUP_FEATURE_ARITHMETIC_BIT ? " arithmetic" : "",
           sub.supportedOperations & VK_SUBGROUP_FEATURE_BALLOT_BIT ? " ballot" : "",
           sub.supportedOperations & VK_SUBGROUP_FEATURE_SHUFFLE_BIT ? " shuffle" : "",
           sub.supportedOperations & VK_SUBGROUP_FEATURE_CLUSTERED_BIT ? " clustered" : "",
           sub.supportedOperations & VK_SUBGROUP_FEATURE_QUAD_BIT ? " quad" : "");
    printf("types: int64 %s, float64 %s, int16 %s, float16 %s, int8 %s; 16-bit storage %s, 8-bit storage %s\n",
           feat.features.shaderInt64 ? "yes" : "no", feat.features.shaderFloat64 ? "yes" : "no",
           feat.features.shaderInt16 ? "yes" : "no", f12.shaderFloat16 ? "yes" : "no", f12.shaderInt8 ? "yes" : "no",
           f11.storageBuffer16BitAccess ? "yes" : "no", f12.storageBuffer8BitAccess ? "yes" : "no");
    printf("memory model: buffer device address %s, Vulkan memory model %s, timeline semaphores %s\n",
           f12.bufferDeviceAddress ? "yes" : "no", f12.vulkanMemoryModel ? "yes" : "no", f12.timelineSemaphore ? "yes" : "no");
    static const char *interesting[] = { "VK_KHR_cooperative_matrix", "VK_NV_cooperative_matrix", "VK_NV_cooperative_matrix2",
        "VK_KHR_shader_bfloat16", "VK_EXT_shader_float8", "VK_KHR_shader_integer_dot_product", "VK_EXT_shader_atomic_float",
        "VK_EXT_shader_atomic_float2", "VK_KHR_ray_query", "VK_KHR_ray_tracing_pipeline", "VK_EXT_mesh_shader",
        "VK_KHR_compute_shader_derivatives", "VK_EXT_subgroup_size_control" };
    printf("extensions:");
    for (size_t i = 0; i < sizeof interesting / sizeof *interesting; i++)
        printf(" %s%s", has_ext(ext, next, interesting[i]) ? "+" : "-", interesting[i] + 3);
    printf("\nmemory: %.1f GiB device-local, %.1f GiB host-visible heaps\n", vram / 1073741824.0, host / 1073741824.0);

    uint32_t nq = 0; vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
    VkQueueFamilyProperties *qf = calloc(nq, sizeof *qf); vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qf);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++) if (qf[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { family = i; break; }
    if (family == UINT32_MAX) die("no compute queue family", VK_SUCCESS);
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family,
                                    .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    VkDevice dev;
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue queue; vkGetDeviceQueue(dev, family, 0, &queue);

    /* two host-visible buffers: x (read) and y (read, written) */
    VkDeviceSize bytes = (VkDeviceSize)n * sizeof(float);
    VkBuffer buf[2]; VkDeviceMemory mem[2]; float *map[2];
    for (int b = 0; b < 2; b++) {
        VkBufferCreateInfo bci = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = bytes,
                                   .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
        CHECK(vkCreateBuffer(dev, &bci, NULL, &buf[b]));
        VkMemoryRequirements req; vkGetBufferMemoryRequirements(dev, buf[b], &req);
        uint32_t type = memory_type(&mp, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        if (type == UINT32_MAX) die("no host-visible, host-coherent memory type for a storage buffer", VK_SUCCESS);
        VkMemoryAllocateInfo mai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = type };
        CHECK(vkAllocateMemory(dev, &mai, NULL, &mem[b]));
        CHECK(vkBindBufferMemory(dev, buf[b], mem[b], 0));
        CHECK(vkMapMemory(dev, mem[b], 0, bytes, 0, (void **)&map[b]));
    }
    const float a = 3.0f;
    for (uint32_t i = 0; i < n; i++) { map[0][i] = (float)(i % 1000) * 0.25f; map[1][i] = 2.0f; }

    VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = kernel_spv_bytes, .pCode = kernel_spv };
    VkShaderModule sm; CHECK(vkCreateShaderModule(dev, &smci, NULL, &sm));
    VkDescriptorSetLayoutBinding bind[2] = {
        { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
        { .binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT } };
    VkDescriptorSetLayoutCreateInfo dslci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = bind };
    VkDescriptorSetLayout dsl; CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
    VkPushConstantRange pcr = { .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = 8 };
    VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl,
                                        .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
    VkPipelineLayout pl; CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &pl));
    VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = sm, .pName = "main" },
        .layout = pl };
    VkPipeline pipe; double t0 = now_ms();
    CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));
    printf("pipeline: SPIR-V compiled for the device in %.0f ms\n", now_ms() - t0);
    VkDescriptorPoolSize dps = { .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 };
    VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &dps };
    VkDescriptorPool dp; CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &dp));
    VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = dp, .descriptorSetCount = 1, .pSetLayouts = &dsl };
    VkDescriptorSet ds; CHECK(vkAllocateDescriptorSets(dev, &dsai, &ds));
    VkDescriptorBufferInfo dbi[2] = { { buf[0], 0, bytes }, { buf[1], 0, bytes } };
    VkWriteDescriptorSet w[2];
    for (int b = 0; b < 2; b++) {
        VkWriteDescriptorSet t = { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = (uint32_t)b,
                                   .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi[b] };
        w[b] = t;
    }
    vkUpdateDescriptorSets(dev, 2, w, 0, NULL);

    VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family,
                                    .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT };
    VkCommandPool cp; CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
    VkCommandBufferAllocateInfo cbai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp,
                                         .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cb; CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; CHECK(vkCreateFence(dev, &fci, NULL, &fence));

    struct { float a; uint32_t n; } push = { a, n };
    double best = 1e30; int runs = 3;
    for (int run = 0; run < runs; run++) {
        for (uint32_t i = 0; i < n; i++) map[1][i] = 2.0f;
        VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        CHECK(vkBeginCommandBuffer(cb, &bi));
        vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
        vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
        vkCmdPushConstants(cb, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof push, &push);
        vkCmdDispatch(cb, (n + 255) / 256, 1, 1);
        VkMemoryBarrier mb = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT };
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &mb, 0, NULL, 0, NULL);
        CHECK(vkEndCommandBuffer(cb));
        VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb };
        CHECK(vkResetFences(dev, 1, &fence));
        double t1 = now_ms();
        CHECK(vkQueueSubmit(queue, 1, &si, fence));
        VkResult wr = vkWaitForFences(dev, 1, &fence, VK_TRUE, 30ull * 1000 * 1000 * 1000);
        if (wr != VK_SUCCESS) die("the dispatch did not complete within 30 s", wr);
        double dt = now_ms() - t1; if (dt < best) best = dt;
    }
    uint32_t bad = 0; uint32_t first_bad = 0; float got_bad = 0, want_bad = 0;
    for (uint32_t i = 0; i < n; i++) {
        float want = a * map[0][i] + 2.0f, got = map[1][i];
        if (fabsf(got - want) > 1e-5f * (1.0f + fabsf(want))) { if (!bad) { first_bad = i; got_bad = got; want_bad = want; } bad++; }
    }
    double gbps = (3.0 * bytes) / (best / 1e3) / 1073741824.0;
    printf("saxpy: %u elements, %d runs, best %.3f ms (%.1f GiB/s through host-visible memory), %u wrong\n", n, runs, best, gbps, bad);
    if (bad) printf("  first wrong at %u: got %g, want %g\n", first_bad, got_bad, want_bad);

    vkDeviceWaitIdle(dev);
    vkDestroyFence(dev, fence, NULL); vkDestroyCommandPool(dev, cp, NULL); vkDestroyDescriptorPool(dev, dp, NULL);
    vkDestroyPipeline(dev, pipe, NULL); vkDestroyPipelineLayout(dev, pl, NULL); vkDestroyDescriptorSetLayout(dev, dsl, NULL);
    vkDestroyShaderModule(dev, sm, NULL);
    for (int b = 0; b < 2; b++) { vkUnmapMemory(dev, mem[b]); vkDestroyBuffer(dev, buf[b], NULL); vkFreeMemory(dev, mem[b], NULL); }
    vkDestroyDevice(dev, NULL); vkDestroyInstance(inst, NULL);
    free(devs); free(ext); free(qf);
    if (bad) { printf("FAIL: %u of %u results are wrong on %s\n", bad, n, props.properties.deviceName); return 1; }
    printf("PASS: Vulkan compute runs on %s through %s %s\n", props.properties.deviceName, drv.driverName, drv.driverInfo);
    return 0;
}
