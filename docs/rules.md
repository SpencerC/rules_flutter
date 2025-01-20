<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Public API re-exports

<a id="flutter_test"></a>

## flutter_test

<pre>
load("@rules_flutter//flutter:defs.bzl", "flutter_test")

flutter_test(<a href="#flutter_test-name">name</a>, <a href="#flutter_test-deps">deps</a>, <a href="#flutter_test-srcs">srcs</a>, <a href="#flutter_test-context">context</a>)
</pre>



**ATTRIBUTES**


| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="flutter_test-name"></a>name |  A unique name for this target.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="flutter_test-deps"></a>deps |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="flutter_test-srcs"></a>srcs |  -   | <a href="https://bazel.build/concepts/labels">List of labels</a> | optional |  `[]`  |
| <a id="flutter_test-context"></a>context |  The context to run the test command.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


<a id="flutter_app"></a>

## flutter_app

<pre>
load("@rules_flutter//flutter:defs.bzl", "flutter_app")

flutter_app(<a href="#flutter_app-name">name</a>, <a href="#flutter_app-pubspec">pubspec</a>, <a href="#flutter_app-pubspec_lock">pubspec_lock</a>, <a href="#flutter_app-srcs">srcs</a>, <a href="#flutter_app-test_files">test_files</a>)
</pre>

Flutter app target.

**PARAMETERS**


| Name  | Description | Default Value |
| :------------- | :------------- | :------------- |
| <a id="flutter_app-name"></a>name |  <p align="center"> - </p>   |  none |
| <a id="flutter_app-pubspec"></a>pubspec |  <p align="center"> - </p>   |  none |
| <a id="flutter_app-pubspec_lock"></a>pubspec_lock |  <p align="center"> - </p>   |  none |
| <a id="flutter_app-srcs"></a>srcs |  <p align="center"> - </p>   |  none |
| <a id="flutter_app-test_files"></a>test_files |  <p align="center"> - </p>   |  `[]` |


