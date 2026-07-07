<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API for Flutter build rules

<a id="dart_format_test"></a>

## dart_format_test

<pre>
load("@rules_flutter//flutter:defs.bzl", "dart_format_test")

dart_format_test(<a href="#dart_format_test-name">name</a>, <a href="#dart_format_test-srcs">srcs</a>)
</pre>

Fails when any of the given Dart sources are not dart-format clean.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="dart_format_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="dart_format_test-srcs"></a>srcs |  Dart sources checked with `dart format --set-exit-if-changed`.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |


<a id="dart_proto_library"></a>

## dart_proto_library

<pre>
load("@rules_flutter//flutter:defs.bzl", "dart_proto_library")

dart_proto_library(<a href="#dart_proto_library-name">name</a>, <a href="#dart_proto_library-deps">deps</a>, <a href="#dart_proto_library-grpc">grpc</a>, <a href="#dart_proto_library-options">options</a>)
</pre>

Generates Dart sources from proto_library targets using the Dart protoc plugin.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="dart_proto_library-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="dart_proto_library-deps"></a>deps |  proto_library targets to generate Dart for. Generation covers the whole transitive proto closure (including well-known types such as google/protobuf/timestamp), matching what generated imports expect.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |
| <a id="dart_proto_library-grpc"></a>grpc |  Deprecated and ignored: gRPC stubs are always generated for protos that declare services.   | Boolean | optional |  `True`  |
| <a id="dart_proto_library-options"></a>options |  Deprecated and ignored.   | List of strings | optional |  `[]`  |


<a id="flutter_analyze_test"></a>

## flutter_analyze_test

<pre>
load("@rules_flutter//flutter:defs.bzl", "flutter_analyze_test")

flutter_analyze_test(<a href="#flutter_analyze_test-name">name</a>, <a href="#flutter_analyze_test-srcs">srcs</a>, <a href="#flutter_analyze_test-embed">embed</a>, <a href="#flutter_analyze_test-extra_args">extra_args</a>, <a href="#flutter_analyze_test-fatal_infos">fatal_infos</a>, <a href="#flutter_analyze_test-fatal_warnings">fatal_warnings</a>)
</pre>

Runs `flutter analyze` hermetically against a prepared flutter_library workspace.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="flutter_analyze_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="flutter_analyze_test-srcs"></a>srcs |  Additional files overlaid before analyzing (e.g. analysis_options.yaml, test sources).   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="flutter_analyze_test-embed"></a>embed |  flutter_library targets whose prepared workspace is analyzed.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="flutter_analyze_test-extra_args"></a>extra_args |  Additional arguments forwarded to flutter analyze.   | List of strings | optional |  `[]`  |
| <a id="flutter_analyze_test-fatal_infos"></a>fatal_infos |  Treat info-level issues as fatal (--fatal-infos).   | Boolean | optional |  `False`  |
| <a id="flutter_analyze_test-fatal_warnings"></a>fatal_warnings |  Treat warnings as fatal; set False to pass --no-fatal-warnings.   | Boolean | optional |  `True`  |


<a id="flutter_test"></a>

## flutter_test

<pre>
load("@rules_flutter//flutter:defs.bzl", "flutter_test")

flutter_test(<a href="#flutter_test-name">name</a>, <a href="#flutter_test-srcs">srcs</a>, <a href="#flutter_test-embed">embed</a>, <a href="#flutter_test-test_files">test_files</a>)
</pre>

Runs Flutter tests using a prepared flutter_library workspace.

**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="flutter_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="flutter_test-srcs"></a>srcs |  Test source files to copy into the runtime workspace.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="flutter_test-embed"></a>embed |  flutter_library targets to embed for testing.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="flutter_test-test_files"></a>test_files |  Test files or directories to run   | List of strings | optional |  `["test/"]`  |


<a id="DartLibraryInfo"></a>

## DartLibraryInfo

<pre>
load("@rules_flutter//flutter:defs.bzl", "DartLibraryInfo")

DartLibraryInfo(<a href="#DartLibraryInfo-srcs">srcs</a>, <a href="#DartLibraryInfo-deps">deps</a>, <a href="#DartLibraryInfo-import_path">import_path</a>, <a href="#DartLibraryInfo-pubspec">pubspec</a>, <a href="#DartLibraryInfo-pub_deps">pub_deps</a>, <a href="#DartLibraryInfo-pub_cache">pub_cache</a>, <a href="#DartLibraryInfo-transitive_pub_caches">transitive_pub_caches</a>,
                <a href="#DartLibraryInfo-assembled_cache">assembled_cache</a>)
</pre>

Information about a Dart library

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="DartLibraryInfo-srcs"></a>srcs |  Source files for this library    |
| <a id="DartLibraryInfo-deps"></a>deps |  Transitive dependencies of this library    |
| <a id="DartLibraryInfo-import_path"></a>import_path |  Import path for this library    |
| <a id="DartLibraryInfo-pubspec"></a>pubspec |  The pubspec.yaml file for this library (optional)    |
| <a id="DartLibraryInfo-pub_deps"></a>pub_deps |  Dependency report copied from checked-in or repository-generated pub_deps.json (optional)    |
| <a id="DartLibraryInfo-pub_cache"></a>pub_cache |  The assembled pub cache directory for this library (optional)    |
| <a id="DartLibraryInfo-transitive_pub_caches"></a>transitive_pub_caches |  Depset of pub cache directories from all transitive dependencies    |
| <a id="DartLibraryInfo-assembled_cache"></a>assembled_cache |  Whether pub_cache contains the full merged dependency closure (assemble_dep_caches). Only such libraries can be embedded.    |


<a id="DartProtoAspectInfo"></a>

## DartProtoAspectInfo

<pre>
load("@rules_flutter//flutter:defs.bzl", "DartProtoAspectInfo")

DartProtoAspectInfo(<a href="#DartProtoAspectInfo-trees">trees</a>)
</pre>

Internal: per-proto_library Dart generation results, propagated along deps.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="DartProtoAspectInfo-trees"></a>trees |  Depset of tree artifacts laid out by proto import path.    |


<a id="DartProtoLibraryInfo"></a>

## DartProtoLibraryInfo

<pre>
load("@rules_flutter//flutter:defs.bzl", "DartProtoLibraryInfo")

DartProtoLibraryInfo(<a href="#DartProtoLibraryInfo-sources">sources</a>)
</pre>

Generated Dart sources produced from .proto files.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="DartProtoLibraryInfo-sources"></a>sources |  Depset of tree artifacts, one per proto_library in the transitive closure, each laid out by proto import path (e.g. `api/v1/service.pb.dart`). Mount them into a package workspace with the `generated_srcs` attribute of flutter_library/dart_library.    |


<a id="FlutterLibraryInfo"></a>

## FlutterLibraryInfo

<pre>
load("@rules_flutter//flutter:defs.bzl", "FlutterLibraryInfo")

FlutterLibraryInfo(<a href="#FlutterLibraryInfo-workspace">workspace</a>, <a href="#FlutterLibraryInfo-pub_get_log">pub_get_log</a>, <a href="#FlutterLibraryInfo-pub_cache">pub_cache</a>, <a href="#FlutterLibraryInfo-pub_deps">pub_deps</a>, <a href="#FlutterLibraryInfo-dart_tool">dart_tool</a>, <a href="#FlutterLibraryInfo-pubspec">pubspec</a>, <a href="#FlutterLibraryInfo-dart_sources">dart_sources</a>,
                   <a href="#FlutterLibraryInfo-other_sources">other_sources</a>, <a href="#FlutterLibraryInfo-transitive_pub_caches">transitive_pub_caches</a>, <a href="#FlutterLibraryInfo-assembled_cache">assembled_cache</a>)
</pre>

Outputs from flutter_library needed to build or test Flutter targets.

**FIELDS**

| Name  | Description |
| :------------- | :------------- |
| <a id="FlutterLibraryInfo-workspace"></a>workspace |  Prepared Flutter workspace tree artifact containing project sources and pub outputs.    |
| <a id="FlutterLibraryInfo-pub_get_log"></a>pub_get_log |  Captured log from dependency preparation (pub deps, cache assembly, and generation commands).    |
| <a id="FlutterLibraryInfo-pub_cache"></a>pub_cache |  Tree artifact containing the assembled pub cache for this library.    |
| <a id="FlutterLibraryInfo-pub_deps"></a>pub_deps |  JSON dependency report copied from checked-in or repository-generated pub_deps.json.    |
| <a id="FlutterLibraryInfo-dart_tool"></a>dart_tool |  Tree artifact containing the generated .dart_tool/package_config.json.    |
| <a id="FlutterLibraryInfo-pubspec"></a>pubspec |  The pubspec.yaml file for this library.    |
| <a id="FlutterLibraryInfo-dart_sources"></a>dart_sources |  Depset of Dart source files that make up the library.    |
| <a id="FlutterLibraryInfo-other_sources"></a>other_sources |  Depset of non-Dart source files bundled with the library.    |
| <a id="FlutterLibraryInfo-transitive_pub_caches"></a>transitive_pub_caches |  Depset of pub cache directories from all transitive dependencies    |
| <a id="FlutterLibraryInfo-assembled_cache"></a>assembled_cache |  Whether pub_cache contains the full merged dependency closure (assemble_dep_caches). Only such libraries can be embedded.    |


<a id="dart_library"></a>

## dart_library

<pre>
load("@rules_flutter//flutter:defs.bzl", "dart_library")

dart_library(<a href="#dart_library-name">name</a>, <a href="#dart_library-create_update_target">create_update_target</a>, <a href="#dart_library-create_format_target">create_format_target</a>, <a href="#dart_library-create_sync_target">create_sync_target</a>,
             <a href="#dart_library-update_visibility">update_visibility</a>, <a href="#dart_library-update_tags">update_tags</a>, <a href="#dart_library-kwargs">**kwargs</a>)
</pre>

Defines a dart_library target and optional .update/.format helpers.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="dart_library-name"></a>name |  Target name for the dart_library rule.   |  none |
| <a id="dart_library-create_update_target"></a>create_update_target |  Whether to emit the runnable `.update` helper (only if pubspec is provided).   |  `True` |
| <a id="dart_library-create_format_target"></a>create_format_target |  Whether to emit the runnable `.format` helper (only if pubspec is provided).   |  `True` |
| <a id="dart_library-create_sync_target"></a>create_sync_target |  Whether to emit the runnable `.sync` helper (only if generated_srcs is set).   |  `True` |
| <a id="dart_library-update_visibility"></a>update_visibility |  Optional visibility override for the `.update` target.   |  `None` |
| <a id="dart_library-update_tags"></a>update_tags |  Optional tag list override for the `.update` target.   |  `None` |
| <a id="dart_library-kwargs"></a>kwargs |  Forwarded to the underlying dart_library rule.   |  none |


<a id="flutter_app"></a>

## flutter_app

<pre>
load("@rules_flutter//flutter:defs.bzl", "flutter_app")

flutter_app(*, <a href="#flutter_app-name">name</a>, <a href="#flutter_app-embed">embed</a>, <a href="#flutter_app-srcs">srcs</a>, <a href="#flutter_app-visibility">visibility</a>, <a href="#flutter_app-tags">tags</a>, <a href="#flutter_app-testonly">testonly</a>, <a href="#flutter_app-dart_defines">dart_defines</a>, <a href="#flutter_app-build_args">build_args</a>, <a href="#flutter_app-mode">mode</a>, <a href="#flutter_app-env">env</a>,
            <a href="#flutter_app-android_sdk">android_sdk</a>, <a href="#flutter_app-android_ndk">android_ndk</a>, <a href="#flutter_app-create_dev_target">create_dev_target</a>, <a href="#flutter_app-dev_run_args">dev_run_args</a>, <a href="#flutter_app-web">web</a>, <a href="#flutter_app-apk">apk</a>, <a href="#flutter_app-appbundle">appbundle</a>, <a href="#flutter_app-ios">ios</a>,
            <a href="#flutter_app-macos">macos</a>, <a href="#flutter_app-linux">linux</a>, <a href="#flutter_app-windows">windows</a>)
</pre>

Macro that defines flutter_app platform targets.

Each platform attribute (`web`, `apk`, `ios`, `macos`, `linux`, `windows`) accepts
either labels for files that should be overlaid into the Flutter workspace when
building for that platform, or a dict spec with any of the keys `srcs`,
`dart_defines`, `build_args`, `mode`, `env`, `android_sdk`, `android_ndk`,
`android_test`, `build_name`, `build_number`, and `tags` to customize that
platform's build. A target is emitted only when the corresponding attribute
is provided. Spec `tags` extend the macro-level `tags` (e.g. to mark only
the mobile platforms `manual`).

Common `dart_defines`/`build_args`/`mode`/`env` apply to every platform;
per-platform values merge over them (`build_args` concatenates, dicts merge
with platform keys winning, `mode` overrides).


**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="flutter_app-name"></a>name |  The base name for the flutter_app targets.   |  none |
| <a id="flutter_app-embed"></a>embed |  List of flutter_library targets to embed.   |  none |
| <a id="flutter_app-srcs"></a>srcs |  Additional source files to include in the build workspace.   |  `None` |
| <a id="flutter_app-visibility"></a>visibility |  Visibility specification for generated targets.   |  `None` |
| <a id="flutter_app-tags"></a>tags |  Tags to apply to generated targets.   |  `None` |
| <a id="flutter_app-testonly"></a>testonly |  Whether the targets are testonly.   |  `False` |
| <a id="flutter_app-dart_defines"></a>dart_defines |  Dict of --dart-define key/value pairs shared by all platforms. Supports select(); compose complete dicts per select() branch.   |  `None` |
| <a id="flutter_app-build_args"></a>build_args |  Extra flutter build arguments shared by all platforms.   |  `None` |
| <a id="flutter_app-mode"></a>mode |  Build mode (release, profile, debug) shared by all platforms.   |  `None` |
| <a id="flutter_app-env"></a>env |  Extra action environment variables shared by all platforms.   |  `None` |
| <a id="flutter_app-android_sdk"></a>android_sdk |  Android SDK directory for apk/appbundle targets (e.g. rules_android's `@androidsdk//:sdk_path`).   |  `None` |
| <a id="flutter_app-android_ndk"></a>android_ndk |  Optional Android NDK directory (e.g. from rules_android_ndk's `@androidndk`).   |  `None` |
| <a id="flutter_app-create_dev_target"></a>create_dev_target |  Whether to emit a runnable `{name}.dev` helper (when `web` is configured) that runs `flutter run -d web-server` in the source workspace with the hermetic SDK and the web dart_defines.   |  `True` |
| <a id="flutter_app-dev_run_args"></a>dev_run_args |  Extra args forwarded to flutter run by the dev helper.   |  `None` |
| <a id="flutter_app-web"></a>web |  Files or dict spec for the {name}.web target.   |  `None` |
| <a id="flutter_app-apk"></a>apk |  Files or dict spec for the {name}.apk target.   |  `None` |
| <a id="flutter_app-appbundle"></a>appbundle |  Files or dict spec for the {name}.appbundle target (Android App Bundle; requires an Android SDK toolchain, see flutter.android_sdk).   |  `None` |
| <a id="flutter_app-ios"></a>ios |  Files or dict spec for the {name}.ios target.   |  `None` |
| <a id="flutter_app-macos"></a>macos |  Files or dict spec for the {name}.macos target.   |  `None` |
| <a id="flutter_app-linux"></a>linux |  Files or dict spec for the {name}.linux target.   |  `None` |
| <a id="flutter_app-windows"></a>windows |  Files or dict spec for the {name}.windows target.   |  `None` |


<a id="flutter_build_settings"></a>

## flutter_build_settings

<pre>
load("@rules_flutter//flutter:defs.bzl", "flutter_build_settings")

flutter_build_settings(<a href="#flutter_build_settings-name">name</a>, <a href="#flutter_build_settings-mode_default">mode_default</a>, <a href="#flutter_build_settings-build_number">build_number</a>, <a href="#flutter_build_settings-visibility">visibility</a>)
</pre>

Emit the command-line build settings a release/multi-env app needs.

flutter_app's `mode` and `build_number` are plain attributes meant to be
driven by `select()` on user build settings. This macro creates the usual
scaffolding so you don't hand-roll it:

- `{name}_mode`: a string_flag over debug/profile/release (default
  `mode_default`), plus a `{name}_<mode>` config_setting for each mode.
- `{name}_build_number`: a string_flag (default empty) when `build_number`
  is True, so a release wrapper can inject a version code on the command
  line instead of rewriting pubspec.yaml.

Wire them into flutter_app, e.g.:

    flutter_app(
        name = "app",
        apk = {
            "srcs": [":android_srcs"],
            "mode": select({
                ":settings_release": "release",
                "//conditions:default": "debug",
            }),
            "build_number": ":settings_build_number",
            "android_sdk": "@androidsdk//:sdk_path",
        },
        ...
    )

then build with `--//your/pkg:settings_mode=release
--//your/pkg:settings_build_number=42`.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="flutter_build_settings-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="flutter_build_settings-mode_default"></a>mode_default |  <p align="center"> - </p>   |  `"release"` |
| <a id="flutter_build_settings-build_number"></a>build_number |  <p align="center"> - </p>   |  `True` |
| <a id="flutter_build_settings-visibility"></a>visibility |  <p align="center"> - </p>   |  `None` |


<a id="flutter_library"></a>

## flutter_library

<pre>
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(<a href="#flutter_library-name">name</a>, <a href="#flutter_library-create_update_target">create_update_target</a>, <a href="#flutter_library-create_format_target">create_format_target</a>, <a href="#flutter_library-create_sync_target">create_sync_target</a>,
                <a href="#flutter_library-update_visibility">update_visibility</a>, <a href="#flutter_library-update_tags">update_tags</a>, <a href="#flutter_library-kwargs">**kwargs</a>)
</pre>

Defines a flutter_library target and optional .update/.format helpers.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="flutter_library-name"></a>name |  Target name for the flutter_library rule.   |  none |
| <a id="flutter_library-create_update_target"></a>create_update_target |  Whether to emit the runnable `.update` helper.   |  `True` |
| <a id="flutter_library-create_format_target"></a>create_format_target |  Whether to emit the runnable `.format` helper (`dart format` write-back over the package source directory).   |  `True` |
| <a id="flutter_library-create_sync_target"></a>create_sync_target |  Whether to emit the runnable `.sync` helper, which writes generated_srcs (e.g. proto outputs) back into the source tree for the IDE analyzer. Only emitted when generated_srcs is set.   |  `True` |
| <a id="flutter_library-update_visibility"></a>update_visibility |  Optional visibility override for the `.update` target.   |  `None` |
| <a id="flutter_library-update_tags"></a>update_tags |  Optional tag list override for the `.update` target.   |  `None` |
| <a id="flutter_library-kwargs"></a>kwargs |  Forwarded to the underlying flutter_library rule.   |  none |


