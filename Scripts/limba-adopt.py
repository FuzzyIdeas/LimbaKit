#!/usr/bin/env python3
"""Add Limba to an Xcode app target, touching only the lines it needs in project.pbxproj.

  1. the LimbaKit package product (a local path or a remote URL),
  2. a Run Script phase that copies String Catalogs and the manifest into Resources/Limba.

  limba-adopt.py App.xcodeproj --target App --package ../Limba \\
      --catalog App/Localizable.xcstrings --manifest Limba/app.json

--package takes a path relative to the folder of the .xcodeproj, or a git URL.
--catalog can be repeated. Paths are relative to the folder of the .xcodeproj.
Running it again changes nothing. Xcode re-sorts the new entries the next time it saves the project.
"""

import argparse
import hashlib
import re
import sys

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("project")
parser.add_argument("--target", required=True)
parser.add_argument("--package", required=True)
parser.add_argument("--catalog", action="append", required=True)
parser.add_argument("--manifest")
parser.add_argument("--version", default="0.2.2", help="minimum version for a remote package")
args = parser.parse_args()

path = args.project.rstrip("/") + "/project.pbxproj"
pbx = open(path, encoding="utf-8").read()
original = pbx
remote = "://" in args.package or args.package.startswith("git@")


def new_id(*parts):
    """A stable 24-digit hex id, so a rerun finds what it added before."""
    return hashlib.sha1("|".join(("limba", args.target) + parts).encode()).hexdigest()[:24].upper()


def object_block(object_id):
    m = re.search(r"\n\t\t" + object_id + r"(?: /\*[^\n]*?\*/)? = \{\n(.*?)\n\t\t\};", pbx, re.S)
    return m


def add_to_list(block_start, block_end, key, entry):
    """Adds `entry` to the list `key = ( ... );` inside pbx[block_start:block_end], creating the list if needed."""
    global pbx
    block = pbx[block_start:block_end]
    m = re.search(r"\n(\t+)" + key + r" = \(\n(.*?)\n\t+\);", block, re.S)
    if m:
        if entry.split(" /*")[0] in m.group(2):
            return
        insert_at = block_start + m.end(2)
        pbx = pbx[:insert_at] + "\n" + m.group(1) + "\t" + entry + "," + pbx[insert_at:]
    else:
        indent = "\t\t\t"
        insert_at = block_start + block.index("\n") + 1
        pbx = pbx[:insert_at] + f"{indent}{key} = (\n{indent}\t{entry},\n{indent});\n" + pbx[insert_at:]


def add_to_section(section, text):
    """Appends an object to `/* Begin <section> section */`, creating the section if needed."""
    global pbx
    end_marker = f"/* End {section} section */"
    if end_marker in pbx:
        i = pbx.index(end_marker)
        pbx = pbx[:i] + text + pbx[i:]
    else:
        i = pbx.index("\t};\n\trootObject")
        pbx = pbx[:i] + f"\n/* Begin {section} section */\n{text}/* End {section} section */\n" + pbx[i:]


# The target
target_match = None
for m in re.finditer(r"\n\t\t([0-9A-Fa-f]{24})(?: /\*[^\n]*?\*/)? = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};", pbx, re.S):
    if re.search(r"\n\t\t\tname = \"?" + re.escape(args.target) + r"\"?;", m.group(2)):
        target_match = m
        break
if not target_match:
    sys.exit(f"No target named {args.target}")
target_id = target_match.group(1)

# 1. Package reference, listed on the project
if remote:
    ref_isa, ref_comment = "XCRemoteSwiftPackageReference", f'XCRemoteSwiftPackageReference "{args.package.rstrip("/").split("/")[-1].removesuffix(".git")}"'
else:
    ref_isa, ref_comment = "XCLocalSwiftPackageReference", f'XCLocalSwiftPackageReference "{args.package}"'

existing_ref = None
for m in re.finditer(r"\n\t\t([0-9A-Fa-f]{24})(?: /\*[^\n]*?\*/)? = \{\n\t\t\tisa = " + ref_isa + r";\n(.*?)\n\t\t\};", pbx, re.S):
    if (remote and args.package in m.group(2)) or (not remote and re.search(r"relativePath = \"?" + re.escape(args.package) + r"\"?;", m.group(2))):
        existing_ref = m.group(1)
ref_id = existing_ref or new_id("ref", args.package)
if not existing_ref:
    if remote:
        body = (f"\t\t\tisa = XCRemoteSwiftPackageReference;\n\t\t\trepositoryURL = \"{args.package}\";\n"
                f"\t\t\trequirement = {{\n\t\t\t\tkind = upToNextMajorVersion;\n\t\t\t\tminimumVersion = {args.version};\n\t\t\t}};\n")
    else:
        rel = args.package if re.fullmatch(r"[A-Za-z0-9_./-]+", args.package) else f'"{args.package}"'
        body = f"\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = {rel};\n"
    add_to_section(ref_isa, f"\t\t{ref_id} /* {ref_comment} */ = {{\n{body}\t\t}};\n")
    project = re.search(r"\n\t\t[0-9A-Fa-f]{24} /\* Project object \*/ = \{\n.*?\n\t\t\};", pbx, re.S)
    if not project:
        project = re.search(r"\n\t\t[0-9A-Fa-f]{24}(?: /\*[^\n]*?\*/)? = \{\n\t\t\tisa = PBXProject;.*?\n\t\t\};", pbx, re.S)
    add_to_list(project.start(), project.end(), "packageReferences", f"{ref_id} /* {ref_comment} */")
    print(f"Added package {args.package}")

# 2. LimbaKit product dependency, linked into the target's Frameworks phase
dep_id = new_id("dep")
if "productName = LimbaKit;" not in pbx:
    add_to_section("XCSwiftPackageProductDependency",
                   f"\t\t{dep_id} /* LimbaKit */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n"
                   f"\t\t\tpackage = {ref_id} /* {ref_comment} */;\n\t\t\tproductName = LimbaKit;\n\t\t}};\n")
    target = object_block(target_id)
    add_to_list(target.start(), target.end(), "packageProductDependencies", f"{dep_id} /* LimbaKit */")

    build_file = new_id("buildfile")
    add_to_section("PBXBuildFile", f"\t\t{build_file} /* LimbaKit in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep_id} /* LimbaKit */; }};\n")
    target = object_block(target_id)
    phases = re.search(r"buildPhases = \((.*?)\);", target.group(1), re.S).group(1)
    for phase_id in re.findall(r"([0-9A-Fa-f]{24})", phases):
        phase = object_block(phase_id)
        if phase and "isa = PBXFrameworksBuildPhase;" in phase.group(1):
            add_to_list(phase.start(), phase.end(), "files", f"{build_file} /* LimbaKit in Frameworks */")
            break
    print(f"Linked LimbaKit into {args.target}")

# 3. Run Script phase that ships the catalogs unprocessed
inputs = [f"$(SRCROOT)/{c}" for c in args.catalog] + ([f"$(SRCROOT)/{args.manifest}"] if args.manifest else [])
outputs = [f"$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Limba/{i.rsplit('/', 1)[-1]}" for i in inputs]
phase_id = new_id("phase")
if "/* Ship strings for Limba */ = {" not in pbx:
    def plist_list(items):
        return "".join(f'\t\t\t\t"{i}",\n' for i in items)
    script = (
        "# Limba: translators read the String Catalogs from Resources/Limba, unprocessed.\\n"
        "# Xcode compiles catalogs listed under Copy Bundle Resources, so they are copied here instead.\\n"
        "for (( i = 0; i < SCRIPT_INPUT_FILE_COUNT; i++ )); do\\n"
        "  input=\\\"SCRIPT_INPUT_FILE_$i\\\"\\n"
        "  output=\\\"SCRIPT_OUTPUT_FILE_$i\\\"\\n"
        "  mkdir -p \\\"$(dirname \\\"${!output}\\\")\\\"\\n"
        "  cp \\\"${!input}\\\" \\\"${!output}\\\"\\n"
        "done\\n"
    )
    add_to_section("PBXShellScriptBuildPhase",
                   f"\t\t{phase_id} /* Ship strings for Limba */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n"
                   f"\t\t\talwaysOutOfDate = 0;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
                   f"\t\t\tinputFileListPaths = (\n\t\t\t);\n\t\t\tinputPaths = (\n{plist_list(inputs)}\t\t\t);\n"
                   f"\t\t\tname = \"Ship strings for Limba\";\n\t\t\toutputFileListPaths = (\n\t\t\t);\n"
                   f"\t\t\toutputPaths = (\n{plist_list(outputs)}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
                   f"\t\t\tshellPath = /bin/bash;\n\t\t\tshellScript = \"{script}\";\n\t\t}};\n")
    target = object_block(target_id)
    add_to_list(target.start(), target.end(), "buildPhases", f"{phase_id} /* Ship strings for Limba */")
    print(f"Run Script phase 'Ship strings for Limba' copies {len(inputs)} file(s)")

if pbx != original:
    open(path, "w", encoding="utf-8").write(pbx)
else:
    print("Nothing to change")
