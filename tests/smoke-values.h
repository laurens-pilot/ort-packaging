#pragma once

#include <cmath>
#include <cstddef>

inline bool ValidMulOutput(const float* actual, size_t count) {
  const float expected[] = {1.0f, 4.0f, 9.0f, 16.0f, 25.0f, 36.0f};
  if (count != 6) {
    return false;
  }
  for (size_t i = 0; i < count; ++i) {
    if (!std::isfinite(actual[i]) || std::fabs(actual[i] - expected[i]) > 1e-5f) {
      return false;
    }
  }
  return true;
}
