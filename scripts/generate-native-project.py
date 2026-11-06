#!/usr/bin/env python3
"""Regenerate the native Xcode project using only the Python standard library.

Xcode synchronized groups automatically include Swift files added to the
source directories. No project generator or package download is required.
"""

from pathlib import Path
from hashlib import sha1
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "native" / "FormFlow.xcodeproj"
TARGETS = ["FormFlowiOS", "FormFlowWatch", "FormFlowiOSTests", "FormFlowUITests"]


def identifier(name):
    return sha1(name.encode()).hexdigest()[:24].upper()


def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def settings(values):
    return "{\n" + "".join(f"\t\t\t\t{k} = {quoted(v)};\n" for k, v in values.items()) + "\t\t\t}"


objects = []


def add(name, isa, fields):
    objects.append(f"\t\t{identifier(name)} /* {name} */ = {{\n\t\t\tisa = {isa};\n{fields}\t\t}};\n")
    return identifier(name)


def ref(name):
    return f"{identifier(name)} /* {name} */"


def array(names):
    return "(\n" + "".join(f"\t\t\t\t{ref(name)},\n" for name in names) + "\t\t\t)"


def field(name, value):
    return f"\t\t\t{name} = {value};\n"


add("Main Group", "PBXGroup", field("children", array(TARGETS + ["Shared", "Products"])) + field("sourceTree", '"<group>"'))
for name in TARGETS + ["Shared"]:
    add(name, "PBXFileSystemSynchronizedRootGroup", field("path", quoted(name)) + field("sourceTree", '"<group>"'))
add("Products", "PBXGroup", field("children", array(["FormFlowiOS.app", "FormFlowWatch.app", "FormFlowiOSTests.xctest", "FormFlowUITests.xctest"])) + field("name", "Products") + field("sourceTree", '"<group>"'))
for name in TARGETS:
    extension = "xctest" if name.endswith("Tests") else "app"
    file_type = "wrapper.cfbundle" if name.endswith("Tests") else "wrapper.application"
    add(f"{name}.{extension}", "PBXFileReference", field("explicitFileType", file_type) + field("includeInIndex", "0") + field("path", quoted(f"{name}.{extension}")) + field("sourceTree", "BUILT_PRODUCTS_DIR"))

add("FormFlowCore package", "XCLocalSwiftPackageReference", field("relativePath", '"../packages/FormFlowCore"'))
for name in TARGETS:
    add(f"{name} Core product", "XCSwiftPackageProductDependency", field("package", ref("FormFlowCore package")) + field("productName", "FormFlowCore"))
    add(f"{name} Core framework", "PBXBuildFile", field("productRef", ref(f"{name} Core product")))
    for phase, isa, files in [("Sources", "PBXSourcesBuildPhase", []), ("Resources", "PBXResourcesBuildPhase", []), ("Frameworks", "PBXFrameworksBuildPhase", [f"{name} Core framework"])]:
        add(f"{name} {phase}", isa, field("buildActionMask", "2147483647") + field("files", array(files)) + field("runOnlyForDeploymentPostprocessing", "0"))

add("Embed Watch app", "PBXBuildFile", field("fileRef", ref("FormFlowWatch.app")) + field("settings", "{ ATTRIBUTES = (RemoveHeadersOnCopy, ); }"))
add("Embed Watch Content", "PBXCopyFilesBuildPhase", field("buildActionMask", "2147483647") + field("dstPath", '"$(CONTENTS_FOLDER_PATH)/Watch"') + field("dstSubfolderSpec", "16") + field("files", array(["Embed Watch app"])) + field("name", '"Embed Watch Content"') + field("runOnlyForDeploymentPostprocessing", "0"))
add("Watch proxy", "PBXContainerItemProxy", field("containerPortal", ref("Project object")) + field("proxyType", "1") + field("remoteGlobalIDString", identifier("FormFlowWatch target")) + field("remoteInfo", "FormFlowWatch"))
add("Watch dependency", "PBXTargetDependency", field("target", ref("FormFlowWatch target")) + field("targetProxy", ref("Watch proxy")))
add("iOS host proxy", "PBXContainerItemProxy", field("containerPortal", ref("Project object")) + field("proxyType", "1") + field("remoteGlobalIDString", identifier("FormFlowiOS target")) + field("remoteInfo", "FormFlowiOS"))
add("iOS host dependency", "PBXTargetDependency", field("target", ref("FormFlowiOS target")) + field("targetProxy", ref("iOS host proxy")))

for name in TARGETS:
    phases = [f"{name} Sources", f"{name} Frameworks", f"{name} Resources"]
    if name == "FormFlowiOS":
        phases.append("Embed Watch Content")
    dependencies = ["Watch dependency"] if name == "FormFlowiOS" else ["iOS host dependency"] if name.endswith("Tests") else []
    source_groups = [name] if name.endswith("Tests") else [name, "Shared"]
    extension = "xctest" if name.endswith("Tests") else "app"
    product_type = "com.apple.product-type.bundle.unit-test" if name.endswith("Tests") else "com.apple.product-type.application"
    if name == "FormFlowUITests":
        product_type = "com.apple.product-type.bundle.ui-testing"
    add(f"{name} target", "PBXNativeTarget", field("buildConfigurationList", ref(f"{name} configurations")) + field("buildPhases", array(phases)) + field("buildRules", "()") + field("dependencies", array(dependencies)) + field("fileSystemSynchronizedGroups", array(source_groups)) + field("name", name) + field("packageProductDependencies", array([f"{name} Core product"])) + field("productName", name) + field("productReference", ref(f"{name}.{extension}")) + field("productType", quoted(product_type)))

project_defaults = {
    "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17", "SWIFT_VERSION": "5.0",
    "SWIFT_STRICT_CONCURRENCY": "complete", "ALWAYS_SEARCH_USER_PATHS": "NO",
}
common_target = {
    "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
    "GENERATE_INFOPLIST_FILE": "YES", "INFOPLIST_KEY_CFBundleDisplayName": "Form / Flow",
    "PRODUCT_NAME": "$(TARGET_NAME)", "SWIFT_EMIT_LOC_STRINGS": "YES",
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
}
target_settings = {
    "FormFlowiOS": {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.formflow.training", "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
        "TARGETED_DEVICE_FAMILY": "1", "SUPPORTS_MACCATALYST": "NO",
        "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
        "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
        "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
        "INFOPLIST_KEY_NSFaceIDUsageDescription": "Unlock your locally stored training records when you enable app lock.",
        "CODE_SIGN_ENTITLEMENTS": "Configuration/FormFlow.entitlements",
        "INFOPLIST_KEY_NSHealthShareUsageDescription": "Show workout heart rate and energy, and reconcile workouts saved by Form / Flow.",
        "INFOPLIST_KEY_NSHealthUpdateUsageDescription": "Save workouts to Apple Health when you choose Health recording.",
    },
    "FormFlowWatch": {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.formflow.training.watchkitapp", "SDKROOT": "watchos",
        "SUPPORTED_PLATFORMS": "watchos watchsimulator", "WATCHOS_DEPLOYMENT_TARGET": "26.0",
        "TARGETED_DEVICE_FAMILY": "4", "SKIP_INSTALL": "YES",
        "INFOPLIST_KEY_WKApplication": "YES",
        "INFOPLIST_KEY_WKCompanionAppBundleIdentifier": "com.formflow.training",
        "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp": "NO",
        "INFOPLIST_FILE": "Configuration/FormFlowWatch-Info.plist",
        "CODE_SIGN_ENTITLEMENTS": "Configuration/FormFlow.entitlements",
        "INFOPLIST_KEY_NSHealthShareUsageDescription": "Show workout heart rate and energy, and reconcile workouts saved by Form / Flow.",
        "INFOPLIST_KEY_NSHealthUpdateUsageDescription": "Save workouts to Apple Health when you choose Health recording.",
    },
    "FormFlowiOSTests": {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.formflow.training.tests", "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
        "TARGETED_DEVICE_FAMILY": "1", "BUNDLE_LOADER": "$(TEST_HOST)",
        "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/FormFlowiOS.app/FormFlowiOS",
    },
    "FormFlowUITests": {
        "PRODUCT_BUNDLE_IDENTIFIER": "com.formflow.training.uitests", "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
        "TARGETED_DEVICE_FAMILY": "1", "TEST_TARGET_NAME": "FormFlowiOS",
    },
}
for owner in ["Project"] + TARGETS:
    for configuration in ["Debug", "Release"]:
        values = dict(project_defaults) if owner == "Project" else {**common_target, **target_settings[owner]}
        if owner == "Project":
            values.update({"DEBUG_INFORMATION_FORMAT": "dwarf" if configuration == "Debug" else "dwarf-with-dsym",
                           "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if configuration == "Debug" else "-O"})
            if configuration == "Debug":
                values.update({"ENABLE_TESTABILITY": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)", "ONLY_ACTIVE_ARCH": "YES"})
            else:
                values.update({"SWIFT_COMPILATION_MODE": "wholemodule", "VALIDATE_PRODUCT": "YES"})
        add(f"{owner} {configuration}", "XCBuildConfiguration", field("buildSettings", settings(values)) + field("name", configuration))
    add(f"{owner} configurations", "XCConfigurationList", field("buildConfigurations", array([f"{owner} Debug", f"{owner} Release"])) + field("defaultConfigurationIsVisible", "0") + field("defaultConfigurationName", "Release"))

add("Project object", "PBXProject", field("attributes", "{ BuildIndependentTargetsInParallel = YES; LastSwiftUpdateCheck = 2700; LastUpgradeCheck = 2700; }") + field("buildConfigurationList", ref("Project configurations")) + field("developmentRegion", "en") + field("hasScannedForEncodings", "0") + field("knownRegions", "(en, Base,)") + field("mainGroup", ref("Main Group")) + field("minimizedProjectReferenceProxies", "1") + field("packageReferences", array(["FormFlowCore package"])) + field("preferredProjectObjectVersion", "77") + field("productRefGroup", ref("Products")) + field("projectDirPath", '""') + field("projectRoot", '""') + field("targets", array([f"{name} target" for name in TARGETS])))

PROJECT.mkdir(parents=True, exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 77;\n\tobjects = {\n" + "".join(objects) + "\t};\n\trootObject = " + ref("Project object") + ";\n}\n")

schemes = PROJECT / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
for name in ["FormFlowiOS", "FormFlowWatch"]:
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier(name + " target")}" BuildableName="{escape(name)}.app" BlueprintName="{escape(name)}" ReferencedContainer="container:FormFlow.xcodeproj"/>'
    test_references = [f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier(test + " target")}" BuildableName="{test}.xctest" BlueprintName="{test}" ReferencedContainer="container:FormFlow.xcodeproj"/>' for test in ["FormFlowiOSTests", "FormFlowUITests"]]
    testables = ''.join(f'<TestableReference skipped="NO">{ref}</TestableReference>' for ref in test_references) if name == "FormFlowiOS" else ""
    test_build = ''.join(f'<BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{ref}</BuildActionEntry>' for ref in test_references) if name == "FormFlowiOS" else ""
    (schemes / f"{name}.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry>{test_build}</BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{testables}</Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {PROJECT.relative_to(ROOT)}")
