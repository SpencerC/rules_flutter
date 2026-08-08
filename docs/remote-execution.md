# Remote execution

`//flutter:allow_remote_execution` drops the `no-remote-exec` tags described in
[hermeticity.md](hermeticity.md). This document is the audit behind that flag:
what already works remotely, what does not, and what is untested. It exists
because "we have a flag for it" and "it works" are different claims, and only
the first one has been true so far.

**Status: opt-in, unverified.** The flag is wired end to end and the actions it
affects are hermetic by construction, but no run against a real RBE fleet has
been recorded. Treat the sections below as an audit, not a support statement.

## Already correct

- **Toolchain resolution.** Toolchains are declared `exec_compatible_with` the
  SDK's platform (`toolchains_repo.bzl`), so an executor of a different OS or
  architecture than the client selects its own Flutter SDK rather than being
  handed the client's. This is the part that is usually wrong in rulesets that
  grew up local-only, and here it is right.
- **No reliance on the client's filesystem layout.** Action command lines are
  built from execroot-relative paths and resolve absolutes through `$PWD` at
  run time, so an executor rooting the tree elsewhere behaves identically.
- **`package_config.json` is regenerated in-action** from declared metadata
  rather than inherited from a `pub get` that ran somewhere else. Absolute
  paths written by pub are the classic way a Dart build breaks when the tree
  moves, and the build actions already defend against it.
- **Resource hints are declared.** `heavy_action_resource_set` asks for 4 CPUs
  and 4GB, so a scheduler that honours them will not put the flutter tool on a
  single-core worker.

## Blockers

- **Android and iOS cannot be remotely executed at all**, and this is not a
  policy choice: they run `no-sandbox` against host-wrapped SDK symlink trees,
  need the network mid-action, and read the client shell environment. They are
  tagged unconditionally and `allow_remote_execution` does not lift them. An
  RBE fleet would have to provide a real Android SDK/NDK and Xcode image, at
  which point the tags are wrong for that fleet specifically — there is no
  general fix, only a per-fleet one.

  `--//flutter:android_gradle_offline` removes one leg of that for Android: with
  the Maven closure, the Gradle distribution and the init script declared as
  inputs, the action no longer needs the network or the client shell
  environment, so `requires-network` and `use_default_shell_env` drop. It does
  **not** make Android remotely executable or remote-cacheable. The SDK is still
  a path reference resolved through rules_android's symlink wrapper to a host
  install, so `no-sandbox`, `no-remote-cache` and `no-remote-exec` all stay. See
  [Android: offline Gradle](hermeticity.md#android-offline-gradle).
- **`//flutter:build_runner_cache` is incompatible by construction.** It hands
  the action an absolute host directory that an executor cannot see. Also
  tagged unconditionally.
- **`@flutter_sdk` is host-resolved.** `sdk_repo.bzl` picks the SDK repo from
  the *client's* platform, and consumers put labels like
  `@flutter_sdk//flutter/packages/flutter` directly in `deps`. Under RE with a
  differing executor platform, those inputs come from the client's SDK. In
  practice they are architecture-independent Dart sources — the native pieces
  arrive through the toolchain, which resolves correctly — so this is a
  latent inconsistency rather than a live bug. It becomes real the moment a
  consumer depends on something under `@flutter_sdk` that is not pure Dart.

## Untested, in rough order of risk

1. **Tree artifact size.** The assembled pub cache is multi-GB and the prepared
   workspace ~100MB, and every one of them would have to cross the wire.
   `remote_cache_trees` exists to make that *possible*, not advisable; the
   upload stalls that motivated the default posture were measured on a cache,
   and an executor pays them on the input side too.
2. **Hardlink assembly.** The pub cache is assembled with hardlinks where the
   filesystem allows and byte copies where it does not
   (`flutter_actions.bzl`). Correct either way, but the fallback is what an
   executor will hit, and its cost has only been measured locally.
3. **Wall-clock.** A preparation step that takes about a minute on an 8-CPU
   worker has been observed taking 50+ minutes on a default-size remote
   executor. That observation is why the local default exists. Nothing about
   it has changed; a fleet needs genuinely large workers before this flag is
   worth flipping.

## If you try it

Run `//:analyze` and the test targets, not just a `flutter build` — the build
actions are the most hermetic thing here, so they are the least likely to
expose a problem. Compare against a local run of the same targets rather than
against a previous remote one, and check that the outputs match rather than
that the build merely succeeded.
