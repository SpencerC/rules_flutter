load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_flutter//flutter:defs.bzl", "dart_library")

# Test library that uses the fixnum package
dart_library(
    name = "fixnum_usage_lib",
    srcs = ["lib/fixnum_usage.dart"],
    deps = [
        "@pub_fixnum//:fixnum",
    ],
)

# Build test to ensure the fixnum package can be used
build_test(
    name = "fixnum_usage_test",
    targets = [":fixnum_usage_lib"],
)

# Test that verifies we can access the fixnum package files
build_test(
    name = "fixnum_package_files_test",
    targets = [
        "@pub_fixnum//:all_files",
        "@pub_fixnum//:pubspec",
    ],
)
