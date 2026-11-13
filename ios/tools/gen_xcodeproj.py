#!/usr/bin/env python3
"""生成可直接用 xcodebuild 打开的 BPCNews.xcodeproj（不依赖 XcodeGen）。

为什么要有这个东西：
  CI 里 `brew install xcodegen` 是个额外故障点；而工程一旦被签入仓库，
  macOS runner 上 `xcodebuild -project BPCNews.xcodeproj` 就能直接编译，
  你手上有 Mac 时也能双击打开。project.yml 仍保留，作为「另一条等价路径」。

产物（全部由本脚本写出，保证与 project.yml 的 Info.plist 键一致）：
  ios/BPCNews.xcodeproj/project.pbxproj
  ios/BPCNews.xcodeproj/xcshareddata/xcschemes/BPCNews.xcscheme
  ios/BPCNews/Info.plist
  ios/BPCNews/BPCNews.entitlements

用法：python ios/tools/gen_xcodeproj.py [--bundle-id com.you.app]
"""
from __future__ import annotations

import argparse
import hashlib
import plistlib
from pathlib import Path

IOS = Path(__file__).resolve().parents[1]
SRC = IOS / "BPCNews"
PROJ = IOS / "BPCNews.xcodeproj"

TARGET_NAME = "BPCNews"
SWIFT_FILES = sorted(p.name for p in SRC.glob("*.swift"))


def uid(label: str) -> str:
    return hashlib.md5(label.encode()).hexdigest()[:24].upper()


U = {
    "project": uid("project"),
    "target": uid("target"),
    "product_ref": uid("product_ref"),
    "main_group": uid("main_group"),
    "src_group": uid("src_group"),
    "products_group": uid("products_group"),
    "sources_phase": uid("sources_phase"),
    "frameworks_phase": uid("frameworks_phase"),
    "resources_phase": uid("resources_phase"),
    "proj_cfg_list": uid("proj_cfg_list"),
    "target_cfg_list": uid("target_cfg_list"),
    "proj_debug": uid("proj_debug"),
    "proj_release": uid("proj_release"),
    "target_debug": uid("target_debug"),
    "target_release": uid("target_release"),
    "info_ref": uid("info_ref"),
    "ent_ref": uid("ent_ref"),
}

INFO_PLIST = {
    "CFBundleDisplayName": "财经速递",
    "CFBundleName": TARGET_NAME,
    "CFBundleExecutable": "$(EXECUTABLE_NAME)",
    "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
    "CFBundleInfoDictionaryVersion": "6.0",
    "CFBundleDevelopmentRegion": "zh_CN",
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "$(MARKETING_VERSION)",
    "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
    "LSRequiresIPhoneOS": True,
    "UILaunchScreen": {},
    "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
    "UIUserInterfaceStyle": "Automatic",
    "UIBackgroundModes": ["fetch", "remote-notification"],
    "BGTaskSchedulerPermittedIdentifiers": ["$(PRODUCT_BUNDLE_IDENTIFIER).refresh"],
    "ITSAppUsesNonExemptEncryption": False,
    "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": False},
}

ENTITLEMENTS = {"aps-environment": "development"}


def build_pbxproj(bundle_id: str) -> str:
    bf = {f: uid("bf:" + f) for f in SWIFT_FILES}
    fr = {f: uid("fr:" + f) for f in SWIFT_FILES}

    lines = []
    a = lines.append

    a("// !$*UTF8*$!")
    a("{")
    a("\tarchiveVersion = 1;")
    a("\tclasses = {")
    a("\t};")
    a("\tobjectVersion = 56;")
    a("\tobjects = {")

    # ---------- PBXBuildFile ----------
    a("")
    a("/* Begin PBXBuildFile section */")
    for f in SWIFT_FILES:
        a("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
          % (bf[f], f, fr[f], f))
    a("/* End PBXBuildFile section */")

    # ---------- PBXFileReference ----------
    a("")
    a("/* Begin PBXFileReference section */")
    for f in SWIFT_FILES:
        a('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
          'path = %s; sourceTree = "<group>"; };' % (fr[f], f, f))
    a('\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; '
      'path = Info.plist; sourceTree = "<group>"; };' % U["info_ref"])
    a('\t\t%s /* BPCNews.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; '
      'path = BPCNews.entitlements; sourceTree = "<group>"; };' % U["ent_ref"])
    a('\t\t%s /* BPCNews.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
      'includeInIndex = 0; path = BPCNews.app; sourceTree = BUILT_PRODUCTS_DIR; };' % U["product_ref"])
    a("/* End PBXFileReference section */")

    # ---------- PBXFrameworksBuildPhase ----------
    a("")
    a("/* Begin PBXFrameworksBuildPhase section */")
    a("\t\t%s /* Frameworks */ = {" % U["frameworks_phase"])
    a("\t\t\tisa = PBXFrameworksBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXFrameworksBuildPhase section */")

    # ---------- PBXGroup ----------
    a("")
    a("/* Begin PBXGroup section */")
    a("\t\t%s = {" % U["main_group"])
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a("\t\t\t\t%s /* BPCNews */," % U["src_group"])
    a("\t\t\t\t%s /* Products */," % U["products_group"])
    a("\t\t\t);")
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")
    a("\t\t%s /* BPCNews */ = {" % U["src_group"])
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    for f in SWIFT_FILES:
        a("\t\t\t\t%s /* %s */," % (fr[f], f))
    a("\t\t\t\t%s /* Info.plist */," % U["info_ref"])
    a("\t\t\t\t%s /* BPCNews.entitlements */," % U["ent_ref"])
    a("\t\t\t);")
    a("\t\t\tpath = BPCNews;")
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")
    a("\t\t%s /* Products */ = {" % U["products_group"])
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a("\t\t\t\t%s /* BPCNews.app */," % U["product_ref"])
    a("\t\t\t);")
    a("\t\t\tname = Products;")
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")
    a("/* End PBXGroup section */")

    # ---------- PBXNativeTarget ----------
    a("")
    a("/* Begin PBXNativeTarget section */")
    a("\t\t%s /* BPCNews */ = {" % U["target"])
    a("\t\t\tisa = PBXNativeTarget;")
    a("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXNativeTarget \"BPCNews\" */;"
      % U["target_cfg_list"])
    a("\t\t\tbuildPhases = (")
    a("\t\t\t\t%s /* Sources */," % U["sources_phase"])
    a("\t\t\t\t%s /* Frameworks */," % U["frameworks_phase"])
    a("\t\t\t\t%s /* Resources */," % U["resources_phase"])
    a("\t\t\t);")
    a("\t\t\tbuildRules = (")
    a("\t\t\t);")
    a("\t\t\tdependencies = (")
    a("\t\t\t);")
    a("\t\t\tname = BPCNews;")
    a("\t\t\tproductName = BPCNews;")
    a("\t\t\tproductReference = %s /* BPCNews.app */;" % U["product_ref"])
    a("\t\t\tproductType = \"com.apple.product-type.application\";")
    a("\t\t};")
    a("/* End PBXNativeTarget section */")

    # ---------- PBXProject ----------
    a("")
    a("/* Begin PBXProject section */")
    a("\t\t%s /* Project object */ = {" % U["project"])
    a("\t\t\tisa = PBXProject;")
    a("\t\t\tattributes = {")
    a("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    a("\t\t\t\tLastUpgradeCheck = 1600;")
    a("\t\t\t\tTargetAttributes = {")
    a("\t\t\t\t\t%s = {" % U["target"])
    a("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    a("\t\t\t\t\t};")
    a("\t\t\t\t};")
    a("\t\t\t};")
    a("\t\t\tbuildConfigurationList = %s /* Build configuration list for PBXProject \"BPCNews\" */;"
      % U["proj_cfg_list"])
    a("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    a("\t\t\tdevelopmentRegion = zh_CN;")
    a("\t\t\thasScannedForEncodings = 0;")
    a("\t\t\tknownRegions = (")
    a("\t\t\t\ten,")
    a("\t\t\t\tBase,")
    a("\t\t\t\t\"zh-Hans\",")
    a("\t\t\t);")
    a("\t\t\tmainGroup = %s;" % U["main_group"])
    a("\t\t\tproductRefGroup = %s /* Products */;" % U["products_group"])
    a("\t\t\tprojectDirPath = \"\";")
    a("\t\t\tprojectRoot = \"\";")
    a("\t\t\ttargets = (")
    a("\t\t\t\t%s /* BPCNews */," % U["target"])
    a("\t\t\t);")
    a("\t\t};")
    a("/* End PBXProject section */")

    # ---------- PBXResourcesBuildPhase ----------
    a("")
    a("/* Begin PBXResourcesBuildPhase section */")
    a("\t\t%s /* Resources */ = {" % U["resources_phase"])
    a("\t\t\tisa = PBXResourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXResourcesBuildPhase section */")

    # ---------- PBXSourcesBuildPhase ----------
    a("")
    a("/* Begin PBXSourcesBuildPhase section */")
    a("\t\t%s /* Sources */ = {" % U["sources_phase"])
    a("\t\t\tisa = PBXSourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    for f in SWIFT_FILES:
        a("\t\t\t\t%s /* %s in Sources */," % (bf[f], f))
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXSourcesBuildPhase section */")

    # ---------- XCBuildConfiguration ----------
    a("")
    a("/* Begin XCBuildConfiguration section */")

    def proj_cfg(uid_, name, debug):
        a("\t\t%s /* %s */ = {" % (uid_, name))
        a("\t\t\tisa = XCBuildConfiguration;")
        a("\t\t\tbuildSettings = {")
        a("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
        a("\t\t\t\tCLANG_ANALYZER_NONNULL = YES;")
        a("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
        a("\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;")
        a("\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;")
        a("\t\t\t\tCOPY_PHASE_STRIP = NO;")
        a("\t\t\t\tDEBUG_INFORMATION_FORMAT = %s;"
          % ("dwarf" if debug else "\"dwarf-with-dsym\""))
        a("\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;")
        a("\t\t\t\tENABLE_TESTABILITY = %s;" % ("YES" if debug else "NO"))
        a("\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;")
        a("\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;")
        a("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
        a("\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;")
        a("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
        a("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;")
        a("\t\t\t\tMTL_ENABLE_DEBUG_INFO = %s;" % ("INCLUDE_SOURCE" if debug else "NO"))
        a("\t\t\t\tONLY_ACTIVE_ARCH = %s;" % ("YES" if debug else "NO"))
        a("\t\t\t\tSDKROOT = iphoneos;")
        a("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = %s;"
          % ("DEBUG" if debug else "\"\""))
        a("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = %s;" % ("\"-Onone\"" if debug else "\"-O\""))
        a("\t\t\t\tSWIFT_COMPILATION_MODE = %s;"
          % ("singlefile" if debug else "wholemodule"))
        a("\t\t\t\tTARGETED_DEVICE_FAMILY = 1;")
        a("\t\t\t};")
        a("\t\t\tname = %s;" % name)
        a("\t\t};")

    def target_cfg(uid_, name, debug):
        a("\t\t%s /* %s */ = {" % (uid_, name))
        a("\t\t\tisa = XCBuildConfiguration;")
        a("\t\t\tbuildSettings = {")
        a("\t\t\t\tCODE_SIGN_ENTITLEMENTS = BPCNews/BPCNews.entitlements;")
        a("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
        a("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
        a("\t\t\t\tENABLE_BITCODE = NO;")
        a("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
        a("\t\t\t\tINFOPLIST_FILE = BPCNews/Info.plist;")
        a("\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 16.0;")
        a("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (")
        a("\t\t\t\t\t\"$(inherited)\",")
        a("\t\t\t\t\t\"@executable_path/Frameworks\",")
        a("\t\t\t\t);")
        a("\t\t\t\tMARKETING_VERSION = 1.0.0;")
        a("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = %s;" % bundle_id)
        a("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
        a("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;")
        a("\t\t\t\tSWIFT_VERSION = 5.0;")
        a("\t\t\t\tTARGETED_DEVICE_FAMILY = 1;")
        a("\t\t\t};")
        a("\t\t\tname = %s;" % name)
        a("\t\t};")

    proj_cfg(U["proj_debug"], "Debug", True)
    proj_cfg(U["proj_release"], "Release", False)
    target_cfg(U["target_debug"], "Debug", True)
    target_cfg(U["target_release"], "Release", False)
    a("/* End XCBuildConfiguration section */")

    # ---------- XCConfigurationList ----------
    a("")
    a("/* Begin XCConfigurationList section */")
    a("\t\t%s /* Build configuration list for PBXProject \"BPCNews\" */ = {" % U["proj_cfg_list"])
    a("\t\t\tisa = XCConfigurationList;")
    a("\t\t\tbuildConfigurations = (")
    a("\t\t\t\t%s /* Debug */," % U["proj_debug"])
    a("\t\t\t\t%s /* Release */," % U["proj_release"])
    a("\t\t\t);")
    a("\t\t\tdefaultConfigurationIsVisible = 0;")
    a("\t\t\tdefaultConfigurationName = Release;")
    a("\t\t};")
    a("\t\t%s /* Build configuration list for PBXNativeTarget \"BPCNews\" */ = {"
      % U["target_cfg_list"])
    a("\t\t\tisa = XCConfigurationList;")
    a("\t\t\tbuildConfigurations = (")
    a("\t\t\t\t%s /* Debug */," % U["target_debug"])
    a("\t\t\t\t%s /* Release */," % U["target_release"])
    a("\t\t\t);")
    a("\t\t\tdefaultConfigurationIsVisible = 0;")
    a("\t\t\tdefaultConfigurationName = Release;")
    a("\t\t};")
    a("/* End XCConfigurationList section */")

    a("\t};")
    a("\trootObject = %s /* Project object */;" % U["project"])
    a("}")
    return "\n".join(lines) + "\n"


def build_scheme() -> str:
    ref = ('<BuildableReference BuildableIdentifier="primary" '
           'BlueprintIdentifier="%s" BuildableName="BPCNews.app" '
           'BlueprintName="BPCNews" ReferencedContainer="container:BPCNews.xcodeproj"/>'
           % U["target"])
    return """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            %s
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         %s
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         %s
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES">
   </ArchiveAction>
</Scheme>
""" % (ref, ref, ref)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle-id", default="com.yourname.bpcnews")
    args = ap.parse_args()

    if not SWIFT_FILES:
        print("!! 没找到 Swift 源文件，检查 ios/BPCNews/")
        return 1

    PROJ.mkdir(parents=True, exist_ok=True)
    scheme_dir = PROJ / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)

    (PROJ / "project.pbxproj").write_text(build_pbxproj(args.bundle_id), encoding="utf-8")
    (scheme_dir / "BPCNews.xcscheme").write_text(build_scheme(), encoding="utf-8")

    with open(SRC / "Info.plist", "wb") as f:
        plistlib.dump(INFO_PLIST, f, fmt=plistlib.FMT_XML)
    with open(SRC / "BPCNews.entitlements", "wb") as f:
        plistlib.dump(ENTITLEMENTS, f, fmt=plistlib.FMT_XML)

    print("[ok] project.pbxproj        (%d swift files, bundle=%s)"
          % (len(SWIFT_FILES), args.bundle_id))
    print("[ok] xcschemes/BPCNews.xcscheme")
    print("[ok] BPCNews/Info.plist")
    print("[ok] BPCNews/BPCNews.entitlements")
    for f in SWIFT_FILES:
        print("     -", f)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
