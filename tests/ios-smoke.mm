#import <Foundation/Foundation.h>

#include "onnxruntime_cxx_api.h"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void CheckStatus(OrtStatus* status) {
  if (status == nullptr) {
    return;
  }

  const OrtApi& api = Ort::GetApi();
  const std::string message = api.GetErrorMessage(status);
  api.ReleaseStatus(status);
  throw std::runtime_error(message);
}

void RunMul(const Ort::Env& env, const char* model_path, Ort::SessionOptions& session_options) {
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
    throw std::runtime_error("Mul smoke test did not return one tensor");
  }

  const float expected[] = {1.0f, 4.0f, 9.0f, 16.0f, 25.0f, 36.0f};
  const float* actual = outputs[0].GetTensorData<float>();
  for (size_t i = 0; i < input.size(); ++i) {
    if (std::fabs(actual[i] - expected[i]) > 1e-5f) {
      throw std::runtime_error("Mul smoke test returned an incorrect value at index " + std::to_string(i));
    }
  }
}

}  // namespace

int main() {
  @autoreleasepool {
    try {
      NSString* model_path = [[NSBundle mainBundle] pathForResource:@"mul_1" ofType:@"onnx"];
      if (model_path == nil) {
        throw std::runtime_error("mul_1.onnx is missing from the app bundle");
      }

      Ort::Env env(ORT_LOGGING_LEVEL_WARNING, "ios-runtime-smoke");
      {
        Ort::SessionOptions cpu_options;
        RunMul(env, model_path.UTF8String, cpu_options);
        std::cout << "CPU_INFERENCE=passed\n";
      }
      {
        Ort::SessionOptions coreml_options;
        CheckStatus(Ort::GetApi().SessionOptionsAppendExecutionProvider(
            coreml_options, "CoreML", nullptr, nullptr, 0));
        RunMul(env, model_path.UTF8String, coreml_options);
        std::cout << "COREML_INFERENCE=passed\n";
      }

      std::cout << "IOS_RUNTIME_SMOKE=passed\n";
      return 0;
    } catch (const std::exception& error) {
      std::cerr << "iOS runtime smoke test failed: " << error.what() << '\n';
      return 1;
    }
  }
}
