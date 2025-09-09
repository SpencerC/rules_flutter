"""Provides a simple way to test your rules as an external workspace.
Add a basic smoke-test target below.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@com_github_spencerc_rules_flutter//flutter:defs.bzl", "dart_library")

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
        "@com_github_spencerc_rules_flutter//flutter:resolved_toolchain",
    ],
)
