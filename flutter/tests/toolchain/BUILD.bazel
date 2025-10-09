load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter:defs.bzl", "dart_library")

# Test that we can resolve the toolchain
build_test(
    name = "toolchain_resolution_test",
    targets = [
        "//flutter:resolved_toolchain",
    ],
)

# Test a simple Dart library
dart_library(
    name = "simple_dart_lib",
    srcs = ["simple_lib.dart"],
)

build_test(
    name = "dart_library_test",
    targets = [":simple_dart_lib"],
)
