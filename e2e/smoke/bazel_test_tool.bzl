"""Pinned Bazel executable for the offline pub extension integration test."""

_SHA256 = {
    "darwin-arm64": "dd466352a3e4d3581b8898740ee1ff208866ccbe25f8d367c5dcb950219587e6",
    "darwin-x86_64": "14c9bcb01303b38192e0e2895051c1bcf19bf89d7e416f5aeeeb48b6b624cfbf",
    "linux-arm64": "049dd21f40ad979db11c3ee68c96a42ce75f1185e69ac61ab20de1501427a410",
    "linux-x86_64": "7668a95db1250f12c40407251e4e203b4ec8bf39bc495d2f485b2d8c99048694",
}

def _bazel_test_tool_impl(ctx):
    os_name = "darwin" if ctx.os.name == "mac os x" else ctx.os.name
    arch = "arm64" if ctx.os.arch in ["aarch64", "arm64"] else ctx.os.arch
    if arch == "amd64":
        arch = "x86_64"
    platform = os_name + "-" + arch
    if platform not in _SHA256:
        fail("Unsupported pub extension test platform: " + platform)
    ctx.download(
        url = "https://releases.bazel.build/9.2.0/release/bazel-9.2.0-" + platform,
        sha256 = _SHA256[platform],
        output = "bazel",
        executable = True,
    )
    ctx.file("BUILD.bazel", 'exports_files(["bazel"], visibility = ["//visibility:public"])\n')

bazel_test_tool = repository_rule(
    implementation = _bazel_test_tool_impl,
    doc = "Fetch Bazel 9.2.0 at repository time, with no test-time downloads.",
)
