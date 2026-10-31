#include "smoke-values.h"

#include <initializer_list>
#include <limits>

int main() {
  float values[] = {1, 4, 9, 16, 25, 36};
  if (!ValidMulOutput(values, 6) || ValidMulOutput(values, 5)) {
    return 1;
  }
  for (const float invalid :
       {std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(), -1.0f}) {
    values[0] = invalid;
    if (ValidMulOutput(values, 6)) {
      return 1;
    }
  }
  return 0;
}
