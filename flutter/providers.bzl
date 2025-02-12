"""Providers returned by Flutter rules."""

FlutterToolchainInfo = provider(
    doc = "Information about how to invoke the tool executable.",
    fields = {
        "flutter": "The Flutter tool executable.",
        "dart": "The Dart tool executable.",
        "deps": "The dependencies of the toolchain.",
        "internal": "Internal information.",
    },
)

FlutterPackageInfo = provider(
    doc = "Information about the context in which a Flutter app is run.",
    fields = {
        "pub_cache": "The pub cache directory.",
        "pubspec": "The pubspec.yaml file.",
        "pubspec_lock": "The pubspec.lock file.",
        "lib": "The lib directory.",
        "bin": "The bin directory.",
        "deps": "The dependencies provided by the package.",
        "pre_pub_cache_deps": "The dependencies provided by the package exculding pub_cache dependencies.",
    },
)
