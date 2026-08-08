import org.gradle.api.artifacts.repositories.MavenArtifactRepository

val mirror = System.getenv("RULES_FLUTTER_MAVEN_MIRROR")
    ?: error("RULES_FLUTTER_MAVEN_MIRROR is required")
val mirrorUri = uri(mirror)
gradle.startParameter.isOffline = true

fun org.gradle.api.artifacts.dsl.RepositoryHandler.useRulesFlutterMirror() {
    clear()
    maven { url = mirrorUri }
}

gradle.settingsEvaluated {
    pluginManagement.repositories.useRulesFlutterMirror()
    dependencyResolutionManagement.repositories.useRulesFlutterMirror()
}
allprojects {
    buildscript.repositories.useRulesFlutterMirror()
    repositories.useRulesFlutterMirror()
}
