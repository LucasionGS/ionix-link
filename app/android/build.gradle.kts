allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// Some plugins (flutter_ringtone_player) still compile against an old SDK, which
// their own androidx dependencies now refuse. Compile every plugin against ours.
subprojects {
    if (project.name != "app") {
        val raise = {
            extensions.findByType<com.android.build.gradle.LibraryExtension>()?.compileSdk = 37
        }
        if (state.executed) raise() else afterEvaluate { raise() }
    }
}
