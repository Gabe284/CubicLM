cmake_minimum_required(VERSION 3.22.1)
project(nnapi_probe LANGUAGES CXX)

add_library(nnapi_probe SHARED nnapi_probe.cpp)

find_library(android_nnapi neuralnetworks REQUIRED)
find_library(android_log log REQUIRED)

target_compile_features(nnapi_probe PRIVATE cxx_std_17)
target_compile_options(nnapi_probe PRIVATE -Wall -Wextra -Werror=return-type)
target_link_libraries(nnapi_probe PRIVATE ${android_nnapi} ${android_log})
