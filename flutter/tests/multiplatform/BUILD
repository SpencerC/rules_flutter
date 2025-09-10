load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("//flutter:defs.bzl", "flutter_app")

# Test building for multiple platforms
flutter_app(
    name = "multiplatform_web",
    srcs = glob(["src/**/*"]),
    target = "web",
)

# TODO: Enable APK builds once Android SDK is set up in CI
# flutter_app(
#     name = "multiplatform_apk",
#     srcs = glob(["src/**/*"]),
#     target = "apk",
# )

# Test that the apps build successfully
build_test(
    name = "multiplatform_build_test",
    targets = [
        ":multiplatform_web",
        # Note: APK builds require Android SDK setup, so commented out for now
        # ":multiplatform_apk",
    ],
)
