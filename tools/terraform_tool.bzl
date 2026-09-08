"""Pinned Terraform CLI for repository administration through Bazel."""

_VERSION = "1.16.1"
_SHA256 = {
    "darwin_amd64": "3f165e7fabdb8ec44151494418efa1e8095c3f589ed8376a93578a96867a062c",
    "darwin_arm64": "e22cba761ddbd4d218939b28715ab3af37aaf8a42efa41f7d75b2c3d73636060",
    "linux_amd64": "745d33b4b02b7980c62a38ec1beea24ee084ea8caf3f503c200554bd9a0cbe49",
    "linux_arm64": "423288a23ab024d42ac05c409972585f7ec0cf1be572b773ad952f9a1c41387d",
}

def _terraform_tool_impl(ctx):
    os_name = "darwin" if ctx.os.name == "mac os x" else ctx.os.name
    arch = "arm64" if ctx.os.arch in ["aarch64", "arm64"] else ctx.os.arch
    if arch == "x86_64":
        arch = "amd64"
    platform = os_name + "_" + arch
    if platform not in _SHA256:
        fail("Unsupported Terraform administration platform: " + platform)
    ctx.download_and_extract(
        url = "https://releases.hashicorp.com/terraform/{0}/terraform_{0}_{1}.zip".format(_VERSION, platform),
        sha256 = _SHA256[platform],
    )
    ctx.file("BUILD.bazel", 'exports_files(["terraform"], visibility = ["//visibility:public"])\n')

terraform_tool = repository_rule(implementation = _terraform_tool_impl)
