"""Provides a simple way to test your rules as an external workspace.
Add a basic smoke-test target below.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_flutter//flutter:defs.bzl", "dart_library")

# Test basic rule functionality
dart_library(
    name = "test_dart_lib",
    srcs = ["test_lib.dart"],
)

build_test(
    name = "smoke_test",
    targets = [
        ":test_dart_lib",
        # Test that we can load the main rules
        "@rules_flutter//flutter:resolved_toolchain",
    ],
)

test_suite(
    name = "integration_tests",
    tests = [
        ":smoke_test",
        "//flutter_app:hello_world_app_test",
        "//flutter_app:hello_world_build_test",
        "//multiplatform:multiplatform_build_test",
    ],
)
