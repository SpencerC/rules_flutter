"""Pinned Bazel executable for the offline pub extension integration test."""

_SHA256 = {
    "darwin-arm64": "8a65ea2de137757774390a16d6f9322bf12ff984abd4553c2521afa19ddf7063",
    "darwin-x86_64": "6dceb9a73ab682c6f2b485cc607bea079cd7fe00d2d080402e7e7a7d73350fe0",
    "linux-arm64": "44e20bcd475259869d943fb2e604a3e31a629bc7333d7d77809b853a85c7c9ea",
    "linux-x86_64": "43445203739a7fd4eb28abbbee8803f24998e6259cc618a3323fb32bd7fa4f30",
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
        url = "https://releases.bazel.build/8.4.0/release/bazel-8.4.0-" + platform,
        sha256 = _SHA256[platform],
        output = "bazel",
        executable = True,
    )
    ctx.file("BUILD.bazel", 'exports_files(["bazel"], visibility = ["//visibility:public"])\n')

bazel_test_tool = repository_rule(
    implementation = _bazel_test_tool_impl,
    doc = "Fetch Bazel 8.4.0 at repository time, with no test-time downloads.",
)
