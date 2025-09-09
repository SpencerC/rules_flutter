load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter:defs.bzl", "flutter_app", "flutter_test")

# Simple Flutter app test
flutter_app(
    name = "hello_world_app",
    srcs = glob(["src/**/*"]),
    target = "web",
)

# Test that the app builds successfully
build_test(
    name = "hello_world_build_test",
    targets = [":hello_world_app"],
)

# Flutter unit tests
flutter_test(
    name = "hello_world_tests",
    srcs = glob(["src/**/*"]),
    test_files = ["test/widget_test.dart"],
)
