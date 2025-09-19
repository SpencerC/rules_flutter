"""Repository rule for downloading Dart packages from pub.dev"""

_DOC = """Download and setup a Dart package from pub.dev"""

_ATTRS = {
    "package": attr.string(
        mandatory = True,
        doc = "Name of the package on pub.dev",
    ),
    "version": attr.string(
        mandatory = True,
        doc = "Version of the package. If not specified, uses the latest version",
    ),
    "pub_dev_url": attr.string(
        default = "https://pub.dev",
        doc = "Base URL for pub.dev API",
    ),
}

def _pub_dev_repository_impl(repository_ctx):
    """Implementation of pub_dev_repository rule."""
    package_name = repository_ctx.attr.package
    version = repository_ctx.attr.version
    pub_dev_url = repository_ctx.attr.pub_dev_url

    # Fetch package metadata from pub.dev API
    api_url = "{}/api/packages/{}".format(pub_dev_url, package_name)

    # Download package metadata
    result = repository_ctx.download(
        url = api_url,
        output = "package_info.json",
    )

    if not result.success:
        fail("Failed to download package information for {}: {}".format(package_name, result))

    # Read and parse the package metadata
    # package_info_content = repository_ctx.read("package_info.json")

    # Construct the archive URL
    # pub.dev uses the format: https://pub.dev/packages/{package}/versions/{version}.tar.gz
    archive_url = "{}/packages/{}/versions/{}.tar.gz".format(pub_dev_url, package_name, version)

    # Download and extract the package archive
    repository_ctx.download_and_extract(
        url = archive_url,
        stripPrefix = "",  # pub.dev packages don't usually have a prefix
    )

    # Read pubspec.yaml to understand the package structure
    # pubspec_content = ""
    # if repository_ctx.path("pubspec.yaml").exists:
    #     pubspec_content = repository_ctx.read("pubspec.yaml")

    # Generate BUILD.bazel file for the package
    build_content = _generate_build_file(package_name, version)
    repository_ctx.file("BUILD.bazel", build_content)

    # Create a simple marker file for debugging
    repository_ctx.file(
        "PUB_PACKAGE_INFO",
        "Package: {}\nVersion: {}\nDownloaded from: {}\n".format(package_name, version, archive_url),
    )

def _generate_build_file(package_name, version):
    """Generate a BUILD.bazel file for the pub package."""

    # Basic BUILD file content
    build_content = '''# Generated BUILD file for pub.dev package: {package}
# Version: {version}

load("@com_github_spencerc_rules_flutter//flutter:defs.bzl", "dart_library")

# Main library target
dart_library(
    name = "{package}",
    srcs = glob([
        "lib/**/*.dart",
    ]),
    visibility = ["//visibility:public"],
)

# Export the main library with a shorter alias
alias(
    name = "lib",
    actual = ":{package}",
    visibility = ["//visibility:public"],
)

# Files for inspection
filegroup(
    name = "all_files",
    srcs = glob(["**/*"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "pubspec",
    srcs = ["pubspec.yaml"],
    visibility = ["//visibility:public"],
)
'''.format(package = package_name, version = version)

    return build_content

pub_dev_repository = repository_rule(
    implementation = _pub_dev_repository_impl,
    attrs = _ATTRS,
    doc = _DOC,
)
