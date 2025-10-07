"""Repository rule for downloading Dart packages from pub.dev.

Features:
- If `version` is omitted, resolves the latest stable version from pub.dev API.
- Generates BUILD targets for the package by analysing pubspec metadata.
"""

load("//flutter/private:package_generation.bzl", "generate_package_build")

_DOC = """Download and setup a Dart package from pub.dev"""

_ATTRS = {
    "package": attr.string(
        mandatory = True,
        doc = "Name of the package on pub.dev",
    ),
    # Version is optional; when omitted we resolve the latest stable version
    "version": attr.string(
        doc = "Version of the package. If omitted, the latest stable is used.",
    ),
    "pub_dev_url": attr.string(
        default = "https://pub.dev",
        doc = "Base URL for pub.dev API",
    ),
    "sdk_repo": attr.string(
        doc = "Repository label providing Flutter SDK packages (e.g. @flutter_macos)",
    ),
}

def _pub_dev_repository_impl(repository_ctx):
    """Implementation of pub_dev_repository rule."""
    package_name = repository_ctx.attr.package
    requested_version = repository_ctx.attr.version
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

    # Determine the version to fetch. If not provided, pick the latest stable
    version = requested_version
    if not version or version.strip() == "":
        content = repository_ctx.read("package_info.json")

        # Try to extract latest stable version from the JSON payload without external tools.
        # We look for the "latest" object and then its "version" field.
        # This is a minimal, robust string search to avoid JSON parsing deps.
        latest_idx = content.find('"latest"')
        if latest_idx != -1:
            ver_key_idx = content.find('"version"', latest_idx)
            if ver_key_idx != -1:
                # Find first quote after the colon
                colon_idx = content.find(":", ver_key_idx)
                if colon_idx != -1:
                    first_quote = content.find('"', colon_idx + 1)
                    second_quote = content.find('"', first_quote + 1) if first_quote != -1 else -1
                    if first_quote != -1 and second_quote != -1:
                        version = content[first_quote + 1:second_quote]
        if not version:
            fail("Could not determine latest version for {} from pub.dev metadata".format(package_name))

    # Construct the archive URL
    # pub.dev uses the format: https://pub.dev/packages/{package}/versions/{version}.tar.gz
    archive_url = "{}/packages/{}/versions/{}.tar.gz".format(pub_dev_url, package_name, version)

    # Download and extract the package archive
    repository_ctx.download_and_extract(
        url = archive_url,
        stripPrefix = "",  # pub.dev packages typically have no prefix
    )

    generate_package_build(
        repository_ctx,
        package_name,
        sdk_repo = repository_ctx.attr.sdk_repo,
    )

    # Create a simple marker file for debugging
    repository_ctx.file(
        "PUB_PACKAGE_INFO",
        "Package: {}\nVersion: {}\nDownloaded from: {}\n".format(package_name, version, archive_url),
    )

pub_dev_repository = repository_rule(
    implementation = _pub_dev_repository_impl,
    attrs = _ATTRS,
    doc = _DOC,
)
