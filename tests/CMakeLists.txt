cmake_minimum_required(VERSION 3.20)
project(ort_packaging_runtime_smoke LANGUAGES CXX)

if(NOT DEFINED ORT_INCLUDE_DIR)
  message(FATAL_ERROR "ORT_INCLUDE_DIR must point to the ONNX Runtime C/C++ API headers")
endif()

add_executable(runtime-smoke runtime-smoke.cpp)
target_compile_features(runtime-smoke PRIVATE cxx_std_17)
target_include_directories(runtime-smoke PRIVATE "${ORT_INCLUDE_DIR}")

if(MSVC)
  target_compile_options(runtime-smoke PRIVATE /W4 /WX)
else()
  target_compile_options(runtime-smoke PRIVATE -Wall -Wextra -Werror)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux" OR CMAKE_SYSTEM_NAME STREQUAL "Android")
    target_link_libraries(runtime-smoke PRIVATE dl)
  endif()
endif()
