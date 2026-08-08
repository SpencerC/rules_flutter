// Analysis-only stand-in for a repository-retargeting init script.
//
// The tests read the action graph without executing it, so this only has to
// exist and be a plausible init script; the real one lives in the consuming
// repository. See docs/hermeticity.md for what such a script has to do.
gradle.beforeSettings {
    logger.info("rules_flutter analysis fixture: would retarget repositories here")
}
