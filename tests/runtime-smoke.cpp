// Loads the packaged ONNX Runtime dynamically so the smoke test does not hide
// missing runtime dependencies behind a link-time dependency.
#define ORT_API_MANUAL_INIT
#include "onnxruntime_cxx_api.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {

using OrtGetApiBaseFunction = const OrtApiBase*(ORT_API_CALL*)();

[[noreturn]] void Fail(const std::string& message) {
  throw std::runtime_error(message);
}

void CheckStatus(const OrtApi& api, OrtStatus* status) {
  if (status == nullptr) {
    return;
  }

  const std::string message = api.GetErrorMessage(status);
  api.ReleaseStatus(status);
  Fail(message);
}

#ifdef _WIN32
std::wstring ToOrtPath(const char* path) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, nullptr, 0);
  if (size == 0) {
    Fail("failed to convert a UTF-8 path to UTF-16");
  }

  std::wstring result(static_cast<size_t>(size), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, result.data(), size) == 0) {
    Fail("failed to convert a UTF-8 path to UTF-16");
  }
  result.pop_back();
  return result;
}

void* LoadRuntime(const char* path) {
  HMODULE handle = LoadLibraryW(ToOrtPath(path).c_str());
  if (handle == nullptr) {
    Fail("LoadLibraryW failed for " + std::string(path) + " with error " + std::to_string(GetLastError()));
  }
  return handle;
}

void* GetSymbol(void* handle, const char* name) {
  FARPROC symbol = GetProcAddress(static_cast<HMODULE>(handle), name);
  if (symbol == nullptr) {
    Fail("GetProcAddress failed for " + std::string(name) + " with error " + std::to_string(GetLastError()));
  }
  return reinterpret_cast<void*>(symbol);
}
#else
std::string ToOrtPath(const char* path) {
  return path;
}

void* LoadRuntime(const char* path) {
  void* handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
  if (handle == nullptr) {
    Fail("dlopen failed for " + std::string(path) + ": " + dlerror());
  }
  return handle;
}

void* GetSymbol(void* handle, const char* name) {
  dlerror();
  void* symbol = dlsym(handle, name);
  if (const char* error = dlerror(); error != nullptr) {
    Fail("dlsym failed for " + std::string(name) + ": " + error);
  }
  return symbol;
}
#endif

void RunMul(const Ort::Env& env, const ORTCHAR_T* model_path, Ort::SessionOptions& session_options) {
  Ort::Session session(env, model_path, session_options);
  std::vector<float> input{1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
  const std::vector<int64_t> input_shape{3, 2};
  Ort::MemoryInfo memory_info = Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);
  Ort::Value input_tensor = Ort::Value::CreateTensor<float>(
      memory_info, input.data(), input.size(), input_shape.data(), input_shape.size());

  const char* input_names[] = {"X"};
  const char* output_names[] = {"Y"};
  auto outputs = session.Run(Ort::RunOptions{nullptr}, input_names, &input_tensor, 1, output_names, 1);
  if (outputs.size() != 1 || !outputs[0].IsTensor()) {
    Fail("Mul smoke test did not return one tensor");
  }

  const auto output_info = outputs[0].GetTensorTypeAndShapeInfo();
  if (output_info.GetShape() != input_shape || output_info.GetElementCount() != input.size()) {
    Fail("Mul smoke test returned the wrong output shape");
  }

  const float expected[] = {1.0f, 4.0f, 9.0f, 16.0f, 25.0f, 36.0f};
  const float* actual = outputs[0].GetTensorData<float>();
  for (size_t i = 0; i < input.size(); ++i) {
    if (std::fabs(actual[i] - expected[i]) > 1e-5f) {
      Fail("Mul smoke test returned an incorrect value at index " + std::to_string(i));
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 6) {
    std::cerr << "usage: runtime-smoke <core> <plugin|builtin:provider|cpu-only> <model> "
                 "<require-webgpu-device:0|1> <backend|->\n";
    return 2;
  }

  try {
    void* core_handle = LoadRuntime(argv[1]);
    auto get_api_base = reinterpret_cast<OrtGetApiBaseFunction>(GetSymbol(core_handle, "OrtGetApiBase"));
    const OrtApiBase* api_base = get_api_base();
    if (api_base == nullptr) {
      Fail("OrtGetApiBase returned null");
    }

    const OrtApi* api = api_base->GetApi(ORT_API_VERSION);
    if (api == nullptr) {
      Fail("packaged runtime does not support the headers' ORT API version");
    }
    Ort::InitApi(api);

    const auto model_path = ToOrtPath(argv[3]);
    Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "packaging-runtime-smoke");
    {
      Ort::SessionOptions cpu_options;
      RunMul(env, model_path.c_str(), cpu_options);
      std::cout << "CPU_INFERENCE=passed\n";
    }

    const std::string provider_spec = argv[2];
    if (provider_spec == "cpu-only") {
      std::cout << "PACKAGED_RUNTIME_INFERENCE=passed:CPU\n";
      return 0;
    }

    const bool builtin_provider = provider_spec.rfind("builtin:", 0) == 0;
    if (builtin_provider) {
      const std::string provider_name = provider_spec.substr(std::string("builtin:").size());
      if (provider_name.empty()) {
        Fail("builtin provider name is empty");
      }

      Ort::SessionOptions provider_options;
      CheckStatus(*api, api->SessionOptionsAppendExecutionProvider(
                            provider_options, provider_name.c_str(), nullptr, nullptr, 0));
      RunMul(env, model_path.c_str(), provider_options);
      std::cout << "BUILTIN_PROVIDER_INFERENCE=passed:" << provider_name << '\n';
      return 0;
    }

    const auto plugin_path = ToOrtPath(argv[2]);
    CheckStatus(*api, api->RegisterExecutionProviderLibrary(env, "webgpu-smoke", plugin_path.c_str()));
    std::cout << "WEBGPU_PLUGIN_REGISTRATION=passed\n";

    const OrtEpDevice* const* devices = nullptr;
    size_t device_count = 0;
    CheckStatus(*api, api->GetEpDevices(env, &devices, &device_count));

    const OrtEpDevice* webgpu_device = nullptr;
    for (size_t i = 0; i < device_count; ++i) {
      const char* name = api->EpDevice_EpName(devices[i]);
      std::cout << "EP_DEVICE=" << (name == nullptr ? "<unnamed>" : name) << '\n';
      if (name != nullptr && std::string(name) == "WebGpuExecutionProvider") {
        webgpu_device = devices[i];
        break;
      }
    }

    const bool require_webgpu = std::string(argv[4]) == "1";
    if (webgpu_device == nullptr) {
      if (require_webgpu) {
        Fail("no WebGPU EP device was discovered on a runner where WebGPU inference is required");
      }
      std::cout << "WEBGPU_INFERENCE=skipped:no-gpu-device\n";
    } else {
      Ort::SessionOptions webgpu_options;
      const char* option_keys[] = {"ep.webgpuexecutionprovider.dawnBackendType"};
      const char* option_values[] = {argv[5]};
      const bool set_backend = std::string(argv[5]) != "-";
      CheckStatus(*api, api->SessionOptionsAppendExecutionProvider_V2(
                            webgpu_options, env, &webgpu_device, 1,
                            set_backend ? option_keys : nullptr,
                            set_backend ? option_values : nullptr,
                            set_backend ? 1 : 0));
      RunMul(env, model_path.c_str(), webgpu_options);
      std::cout << "WEBGPU_INFERENCE=passed\n";
    }

    CheckStatus(*api, api->UnregisterExecutionProviderLibrary(env, "webgpu-smoke"));
    std::cout << "WEBGPU_PLUGIN_UNREGISTRATION=passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "runtime smoke test failed: " << error.what() << '\n';
    return 1;
  }
}
