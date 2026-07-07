<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Extensions for bzlmod.

Installs a flutter toolchain.
Every module can define a toolchain version under the default name, "flutter".
The latest of those versions will be selected (the rest discarded),
and will always be registered by rules_flutter.

Additionally, the root module can define arbitrarily many more toolchain versions under different
names (the latest version will be picked for each name) and can register them as it sees fit,
effectively overriding the default named toolchain due to toolchain resolution precedence.

<a id="flutter"></a>

## flutter

<pre>
flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(<a href="#flutter.toolchain-name">name</a>, <a href="#flutter.toolchain-flutter_version">flutter_version</a>, <a href="#flutter.toolchain-integrity">integrity</a>, <a href="#flutter.toolchain-precache">precache</a>)
</pre>


**TAG CLASSES**

<a id="flutter.toolchain"></a>

### toolchain

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="flutter.toolchain-name"></a>name |  Base name for generated repositories, allowing more than one flutter toolchain to be registered. Overriding the default is only permitted in the root module.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | optional |  `"flutter"`  |
| <a id="flutter.toolchain-flutter_version"></a>flutter_version |  Explicit version of flutter.   | String | required |  |
| <a id="flutter.toolchain-integrity"></a>integrity |  Escape hatch for Flutter versions not in the built-in version table: a map from platform (macos, linux, windows) to the SRI integrity of that platform's stable release archive, e.g. {"macos": "sha256-...", "linux": "sha256-..."}. Only the platforms you actually build on need an entry (the per-platform SDK repositories are fetched lazily). When flutter_version is in the built-in table this may be omitted. Merged across registrations of the same name.   | <a href="https://bazel.build/rules/lib/dict">Dictionary: String -> String</a> | optional |  `{}`  |
| <a id="flutter.toolchain-precache"></a>precache |  Artifact groups (web, android, ios, macos, linux, windows) that must be present in the SDK cache after fetch. Stable archives already ship these; when one is missing, `flutter precache` runs at repository fetch time. Unioned across registrations of the same toolchain name.   | List of strings | optional |  `[]`  |


<a id="pub"></a>

## pub

<pre>
pub = use_extension("@rules_flutter//flutter:extensions.bzl", "pub")
pub.package(<a href="#pub.package-name">name</a>, <a href="#pub.package-package">package</a>, <a href="#pub.package-version">version</a>)
</pre>


**TAG CLASSES**

<a id="pub.package"></a>

### package

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="pub.package-name"></a>name |  Repository name for the package   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="pub.package-package"></a>package |  Package name on pub.dev   | String | required |  |
| <a id="pub.package-version"></a>version |  Package version (optional, defaults to latest)   | String | optional |  `""`  |


