"""Files that a pub package's build hook reads from the workspace.

Some packages' build hooks (`hook/build.dart`) download native binaries at
build time, typically from GitHub releases. Inside Bazel that turns every
Flutter build and test action into a network client, and a failed download
fails the action. Packages like this often have a mode where the hook reads
the same files from a local directory instead, selected through
`hooks.user_defines` in the root pubspec.yaml.

`flutter_hook_assets` describes that local mode for one package: the files,
and the user_defines that select it. A flutter_library that lists it in
`hook_assets` mounts the files into its workspace and adds the user_defines to
the workspace's pubspec.yaml, so the hook reads the files from Bazel instead of
downloading them, without the source pubspec.yaml mentioning Bazel paths.
"""

FlutterHookAssetsInfo = provider(
    doc = "Files a pub package's build hook reads, and the user_defines that point it at them.",
    fields = {
        "package": "Name of the pub package whose build hook reads the files.",
        "files": "Depset of the files, mounted flat into one workspace directory.",
        "user_defines": "Dict of string user_defines to set for the package.",
        "directory_define": "user_defines key that receives the mount directory, or empty.",
    },
)

def hook_assets_mount_dir(package):
    """Workspace-relative directory where a package's hook assets are mounted."""
    return ".rules_flutter/hook_assets/" + package

def _flutter_hook_assets_impl(ctx):
    if ctx.attr.directory_define in ctx.attr.user_defines:
        fail("user_defines must not set '{}': directory_define fills it with the mount directory".format(
            ctx.attr.directory_define,
        ))
    files = depset(ctx.files.srcs)
    return [
        DefaultInfo(files = files),
        FlutterHookAssetsInfo(
            package = ctx.attr.package,
            files = files,
            user_defines = dict(ctx.attr.user_defines),
            directory_define = ctx.attr.directory_define,
        ),
    ]

flutter_hook_assets = rule(
    implementation = _flutter_hook_assets_impl,
    doc = """Files that a pub package's build hook reads instead of downloading them.

List the target in a flutter_library's `hook_assets`. The library mounts `srcs`
flat into `.rules_flutter/hook_assets/<package>/` in its workspace and adds
`hooks.user_defines.<package>` to the workspace's pubspec.yaml, with
`directory_define` set to that directory (with a trailing slash). The source
pubspec.yaml stays unchanged and must not declare a top-level `hooks:` section.

For packages with a known adapter, `pub.hook_assets` in MODULE.bazel generates
this target, including the downloads. Use the rule directly for other packages:

```starlark
flutter_hook_assets(
    name = "foo_hook_assets",
    package = "foo",
    srcs = ["@foo_prebuilt//:libraries"],
    user_defines = {"source": "local"},
    directory_define = "directory",
)
```
""",
    attrs = {
        "package": attr.string(
            mandatory = True,
            doc = "Name of the pub package whose build hook reads the files.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Files the hook reads. They are mounted flat, by basename.",
        ),
        "user_defines": attr.string_dict(
            doc = "user_defines that select the hook's local-file mode, e.g. `{\"source\": \"local\"}`.",
        ),
        "directory_define": attr.string(
            doc = "user_defines key to set to the mount directory, with a trailing slash. Empty sets none.",
        ),
    },
    provides = [FlutterHookAssetsInfo],
)

def _yaml_string(value):
    # A JSON string is a valid double-quoted YAML scalar.
    return json.encode(value)

def render_hook_user_defines(assets):
    """Render the pubspec.yaml `hooks:` section for a list of FlutterHookAssetsInfo.

    Args:
      assets: FlutterHookAssetsInfo providers, at most one per package.

    Returns:
      The YAML text to append to pubspec.yaml, or "" when assets is empty.
    """
    if not assets:
        return ""
    lines = ["", "# Added by rules_flutter for flutter_library.hook_assets.", "hooks:", "  user_defines:"]
    seen = {}
    for info in sorted(assets, key = lambda i: i.package):
        if info.package in seen:
            fail("hook_assets lists package '{}' more than once".format(info.package))
        seen[info.package] = True
        defines = dict(info.user_defines)
        if info.directory_define:
            # The trailing slash matters: hooks resolve file names against
            # the directory as a URI, which drops a last segment without one.
            defines[info.directory_define] = hook_assets_mount_dir(info.package) + "/"
        lines.append("    {}:".format(_yaml_string(info.package)))
        if not defines:
            lines[-1] += " {}"
        for key in sorted(defines.keys()):
            lines.append("      {}: {}".format(_yaml_string(key), _yaml_string(defines[key])))
    return "\n".join(lines) + "\n"

def hook_assets_entries(assets):
    """Workspace mounts for a list of FlutterHookAssetsInfo.

    Args:
      assets: FlutterHookAssetsInfo providers.

    Returns:
      A list of (workspace-relative path, file) tuples.
    """
    entries = []
    for info in assets:
        mount_dir = hook_assets_mount_dir(info.package)
        for f in info.files.to_list():
            if f.is_directory:
                fail("hook_assets for '{}' must list files, not the directory {}".format(info.package, f.path))
            entries.append((mount_dir + "/" + f.basename, f))
    return entries
