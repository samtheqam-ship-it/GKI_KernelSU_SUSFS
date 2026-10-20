#!/usr/bin/env python3
"""NP03J build contracts. No device access, no private-key publication."""
from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / ".github/np03j/profile.json"
SHA = re.compile(r"[0-9a-f]{40}\Z")
REPOS = {
    "official": ("https://github.com/KernelSU-Next/KernelSU-Next.git", "refs/heads/dev"),
    "root": ("https://github.com/pershoot/KernelSU-Next.git", "refs/heads/dev-susfs"),
    "susfs": ("https://gitlab.com/simonpunk/susfs4ksu.git", "refs/heads/gki-android14-6.1"),
    "nomount": ("https://github.com/maxsteeel/nomount.git", "refs/heads/dev"),
    "bbg": ("https://github.com/vc-teahouse/Baseband-guard.git", "refs/heads/main"),
    "patches": ("https://github.com/WildKernels/kernel_patches.git", "refs/heads/main"),
    "anykernel": ("https://github.com/WildKernels/AnyKernel3.git", "refs/heads/gki-2.0"),
    "manifest": ("https://android.googlesource.com/kernel/manifest", "refs/heads/common-android14-6.1-lts"),
}
SUSFS_FIXES = ("6387756d64b3ab9ececefc4523627a9ee05a7519", "161c058fed5544a6573d87124f346dadd5c4962d")
REQUIRED_CONFIG = (
    "KSU", "KSU_SUSFS", "KSU_SUSFS_SUS_PATH", "KSU_SUSFS_SUS_MOUNT",
    "KSU_SUSFS_SUS_KSTAT", "KSU_SUSFS_SPOOF_UNAME", "KSU_SUSFS_ENABLE_LOG",
    "KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS", "KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG",
    "KSU_SUSFS_OPEN_REDIRECT", "KSU_SUSFS_SUS_MAP", "NOMOUNT", "BBG",
    "ARM64_4K_PAGES", "MODVERSIONS",
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(*args, cwd=None, capture=False, env=None):
    return subprocess.run([str(a) for a in args], cwd=cwd, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None,
                          env=env).stdout


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text())


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def locked_profile():
    p = read_json(PROFILE)
    fixed = {"device": "NP03J", "device_kmi": "6.1-android14-11", "release_type": "Release", "use_cache": False,
             "allow_version_mismatch": False, "kernel_family": "android14-6.1",
             "os_patch_level": "lts", "root_flavor": "KernelSU-Next", "page_size": "4k",
             "commit_mode": "latest", "brand_name": "", "keep_kmi": True,
             "use_susfs": True, "use_nomount": True, "use_bbg": True}
    for key, value in fixed.items():
        require(p.get(key) == value, f"Profile contract changed: {key}")
    for key in ("net", "ds", "ntsync", "ptrace", "unicode", "bpf", "perf"):
        require(p.get("use_" + key) is False, f"Unexpected feature: {key}")
    require(re.fullmatch(r"[a-z]{8}\.[a-z]{8}\.[a-z]{8}", p["manager_package"]),
            "Invalid fixed spoofed package identity")
    return p


def remote_sha(url, ref):
    for attempt in range(3):
        try:
            output = subprocess.check_output(
                ["git", "ls-remote", "--exit-code", url, ref], text=True, timeout=120)
            matches = [line.split()[0] for line in output.splitlines()
                       if line.split()[1] == ref]
            require(len(matches) == 1 and SHA.fullmatch(matches[0]), f"Unresolved ref {url} {ref}")
            return matches[0]
        except (subprocess.SubprocessError, RuntimeError):
            if attempt == 2:
                raise
            time.sleep(3 * (attempt + 1))


def clone_at(url, sha, destination, full=False):
    require(SHA.fullmatch(sha), "Invalid immutable source revision")
    destination = Path(destination)
    require(not destination.exists(), f"Refusing to reuse source checkout: {destination}")
    if full:
        run("git", "clone", "--filter=blob:none", "--no-checkout", url, destination)
    else:
        run("git", "init", destination)
        run("git", "remote", "add", "origin", url, cwd=destination)
    fetch = ["git", "fetch", "--no-tags"]
    if not full:
        fetch += ["--depth=1"]
    run(*fetch, "origin", sha, cwd=destination)
    run("git", "checkout", "--detach", sha, cwd=destination)
    require(run("git", "rev-parse", "HEAD", cwd=destination, capture=True).strip() == sha,
            f"Source checkout mismatch: {destination}")


def uapi_version(text):
    matches = re.findall(r"KERNEL_SU_UAPI_VERSION\s*=\s*(\d+)\s*;", text)
    require(len(matches) == 1, "Cannot uniquely determine KSU UAPI version")
    return int(matches[0])


def resolve(output, workspace):
    p = locked_profile()
    output, workspace = Path(output).resolve(), Path(workspace).resolve()
    output.mkdir(parents=True, exist_ok=True)
    workspace.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=6) as pool:
        sources = dict(pool.map(lambda item: (item[0], {"url": item[1][0],
                    "ref": item[1][1], "sha": remote_sha(*item[1])}), REPOS.items()))
    official = workspace / "official"
    clone_at(sources["official"]["url"], sources["official"]["sha"], official, full=True)
    run("git", "fetch", "--no-tags", sources["root"]["url"], sources["root"]["sha"], cwd=official)
    a, b = sources["official"]["sha"], sources["root"]["sha"]
    run("git", "merge-base", "--is-ancestor", a, b, cwd=official)
    require(run("git", "rev-parse", f"{a}:uapi", cwd=official, capture=True).strip() ==
            run("git", "rev-parse", f"{b}:uapi", cwd=official, capture=True).strip(),
            "Official manager and SUSFS root UAPI trees differ; no fallback is allowed")
    header = run("git", "show", f"{a}:uapi/supercall.h", cwd=official, capture=True)
    version_code = 30000 + int(run("git", "rev-list", "--count", a, cwd=official, capture=True))
    manifest = workspace / "manifest"
    clone_at(sources["manifest"]["url"], sources["manifest"]["sha"], manifest)
    xml = ET.parse(manifest / "default.xml")
    root = xml.getroot()
    require(not root.findall("include") and not root.findall("extend-project"),
            "Manifest structure changed; explicit review is required")
    default = root.find("default")
    require(default is not None, "Manifest has no default revision")
    remotes = {r.attrib["name"]: r.attrib["fetch"] for r in root.findall("remote")}
    projects = []
    for project in root.findall("project"):
        attrs = project.attrib
        require(remotes.get(attrs.get("remote", default.attrib.get("remote"))) == "..",
                "Unexpected manifest remote")
        name, path = attrs["name"], attrs.get("path", attrs["name"])
        require(not Path(path).is_absolute() and ".." not in Path(path).parts, "Unsafe project path")
        revision = attrs.get("revision", default.attrib["revision"])
        projects.append({"name": name, "path": path,
                         "url": "https://android.googlesource.com/" + name,
                         "ref": revision if revision.startswith("refs/") else "refs/heads/" + revision})
    def pin(project):
        project["sha"] = remote_sha(project["url"], project["ref"])
        return project
    with ThreadPoolExecutor(max_workers=6) as pool:
        projects = list(pool.map(pin, projects))
    common = [x for x in projects if x["path"] == "common"]
    require(len(common) == 1 and common[0]["ref"] == "refs/heads/android14-6.1-lts",
            "Manifest no longer selects the expected Android LTS branch")
    lock = {"schema": 1, "resolved_utc": datetime.now(timezone.utc).isoformat(),
            "workflow_sha": os.environ.get("GITHUB_SHA", "local-review"),
            "profile": p, "profile_sha256": digest(PROFILE.read_bytes()),
            "sources": sources, "projects": projects, "manager_version_code": version_code,
            "official_describe": run("git", "describe", "--tags", "--always", a, cwd=official, capture=True).strip(),
            "uapi_version": uapi_version(header),
            "official_manager_workflow_sha256": digest((official / ".github/workflows/build-manager-ci.yml").read_bytes())}
    write_json(output / "source-lock.json", lock)
    shutil.copy2(manifest / "default.xml", output / "upstream-manifest.xml")
    summary = {k: v["sha"] for k, v in sources.items()}
    print(json.dumps({"sources": summary, "kernel_sha": common[0]["sha"],
                      "manager_version_code": version_code, "uapi_version": lock["uapi_version"]}, indent=2))


def load_lock(path):
    lock = read_json(path)
    require(lock["profile_sha256"] == digest(PROFILE.read_bytes()), "Profile changed after source resolution")
    require(lock["profile"] == locked_profile(), "Source lock profile mismatch")
    require(set(lock["sources"]) == set(REPOS), "Missing or unexpected source repository")
    for key, source in lock["sources"].items():
        require(SHA.fullmatch(source["sha"]), "Invalid locked SHA")
        require((source["url"], source["ref"]) == REPOS[key], "Locked repository identity changed")
    paths = set()
    for project in lock["projects"]:
        require(SHA.fullmatch(project["sha"]), "Invalid project SHA")
        path = Path(project["path"])
        require(not path.is_absolute() and ".." not in path.parts and str(path) not in paths,
                "Unsafe or duplicate locked project path")
        paths.add(str(path))
        require(project["url"] == "https://android.googlesource.com/" + project["name"], "Unexpected project URL")
    require("common" in paths and "build/kernel" in paths, "Incomplete kernel manifest")
    return lock


def sync_kernel(lock_path, kernel):
    lock, kernel = load_lock(lock_path), Path(kernel).resolve()
    kernel.mkdir(parents=True, exist_ok=True)
    repo = ROOT / "git-repo/repo"
    source = lock["sources"]["manifest"]
    run(repo, "init", "-u", source["url"], "-b", source["sha"], "--depth=1", "--no-clone-bundle", "--no-use-superproject", cwd=kernel)
    actual = run("git", "rev-parse", "HEAD", cwd=kernel / ".repo/manifests", capture=True).strip()
    require(actual == source["sha"], "Manifest checkout drifted")
    local = ET.Element("manifest")
    for project in lock["projects"]:
        ET.SubElement(local, "extend-project", name=project["name"], path=project["path"],
                      revision=project["sha"], upstream=project["ref"])
    dst = kernel / ".repo/local_manifests/np03j.xml"
    dst.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(local).write(dst, encoding="utf-8", xml_declaration=True)
    for attempt in range(3):
        try:
            run(repo, "sync", "-c", "--no-clone-bundle", "--no-tags", "--jobs-checkout=4", "-j4", cwd=kernel)
            break
        except subprocess.CalledProcessError:
            if attempt == 2:
                raise
            time.sleep(10)
    for project in lock["projects"]:
        actual = run("git", "rev-parse", "HEAD", cwd=kernel / project["path"], capture=True).strip()
        require(actual == project["sha"], f"Project revision drift: {project['path']}")
    manifest_text = run(repo, "manifest", "-r", cwd=kernel, capture=True)
    (kernel / "np03j-resolved-manifest.xml").write_text(manifest_text)
    text = (kernel / "common/Makefile").read_text()
    values = {k: int(re.search(rf"^{k}\s*=\s*(\d+)$", text, re.M)[1])
              for k in ("VERSION", "PATCHLEVEL", "SUBLEVEL")}
    require(values["VERSION"] == 6 and values["PATCHLEVEL"] == 1 and values["SUBLEVEL"] >= 145,
            "Unexpected kernel family or downgrade")
    generation = re.search(r"^KMI_GENERATION=(\d+)$", (kernel / "common/build.config.common").read_text(), re.M)
    require(generation and "6.1-android14-" + generation[1] == lock["profile"]["device_kmi"],
            "Latest LTS no longer matches this device's KMI generation")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as f:
            f.write(f"sublevel={values['SUBLEVEL']}\n")


def prepare_manager(lock_path, checkout):
    lock, checkout = load_lock(lock_path), Path(checkout).resolve()
    source = lock["sources"]["official"]
    clone_at(source["url"], source["sha"], checkout, full=True)
    require(30000 + int(run("git", "rev-list", "--count", "HEAD", cwd=checkout, capture=True)) ==
            lock["manager_version_code"], "Manager history/version mismatch")
    manager = checkout / "manager"
    spoof = manager / "spoof"
    text = spoof.read_text()
    package = lock["profile"]["manager_package"]
    for i, word in enumerate(package.split("."), 1):
        text, count = re.subn(rf"^word{i}=.*$", f"word{i}='{word}'", text, flags=re.M)
        require(count == 1, "Official spoof script changed; refusing a random identity")
    spoof.write_text(text)
    run("bash", "spoof", cwd=manager)
    require(f'namespace = "{package}"' in (manager / "app/build.gradle.kts").read_text(),
            "Fixed spoofed identity did not reach manager namespace")
    app = manager / "app/build.gradle.kts"
    text, count = re.subn(r'versionName = rootProject\.extra\["managerVersionName"\] as String',
                          'versionName = (rootProject.extra["managerVersionName"] as String) + "-spoofed"', app.read_text())
    require(count == 1 or (count == 0 and not re.search(r"^\s*versionName\s*=", text, re.M)),
            "Manager app version-name configuration changed")
    app.write_text(text)
    rust_build = checkout / "userspace/ksud/build.rs"
    text, count = re.subn(r'^\s*builder = builder\.clang_arg\("-I/usr/include"\);$',
                          '        // NP03J: bindgen uses the target NDK sysroot, not host glibc headers.',
                          rust_build.read_text(), flags=re.M)
    require(count == 1, "Official bindgen host-header configuration changed")
    rust_build.write_text(text)
    build = manager / "build.gradle.kts"
    text, count = re.subn(r'abiFilters\("arm64-v8a", "x86_64", "riscv64"\)',
                          'abiFilters("arm64-v8a")', build.read_text())
    require(count == 1, "Manager architecture configuration changed")
    text, count = re.subn(r'abiFilters \+= listOf\("arm64-v8a", "x86_64", "riscv64"\)',
                          'abiFilters += listOf("arm64-v8a")', text)
    require(count == 1, "Manager NDK architecture configuration changed")
    build.write_text(text)
    sdk = re.search(r"val androidCompileSdkVersion = (\d+)", text)
    tools = re.search(r'val androidBuildToolsVersion = "([\d.]+)"', text)
    ndk = re.search(r'^ndk = "([\d.]+)"', (manager / "gradle/libs.versions.toml").read_text(), re.M)
    require(all((sdk, tools, ndk)), "Cannot derive Android toolchain from official source")
    values = {"compile_sdk": sdk[1], "build_tools": tools[1], "ndk": ndk[1]}
    write_json(checkout / "np03j-toolchain.json", values)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            for key, value in values.items():
                f.write(f"{key}={value}\n")


def decode_signing(checkout):
    checkout = Path(checkout)
    encoded = os.environ.get("NP03J_KEYSTORE_B64", "")
    password = os.environ.get("NP03J_KEYSTORE_PASSWORD", "")
    require(encoded and password, "Set NP03J_KEYSTORE_B64 and NP03J_KEYSTORE_PASSWORD repository secrets first")
    require(re.fullmatch(r"[A-Za-z0-9_-]{24,128}", password), "Signing password must be 24-128 URL-safe characters")
    data = base64.b64decode(encoded, validate=True)
    require(0 < len(data) < 32000, "Invalid signing keystore size")
    manager = checkout / "manager"
    key = manager / "np03j-signing.p12"
    key.write_bytes(data)
    key.chmod(0o600)
    props = manager / "gradle.properties"
    with props.open("a") as f:
        f.write("\nKEYSTORE_FILE=np03j-signing.p12\nKEY_ALIAS=np03j\n")
        f.write(f"KEYSTORE_PASSWORD={password}\nKEY_PASSWORD={password}\n")
    props.chmod(0o600)
    run("keytool", "-exportcert", "-keystore", key, "-storetype", "PKCS12", "-alias", "np03j",
        "-storepass:env", "NP03J_KEYSTORE_PASSWORD", "-file", checkout / "np03j-manager-cert.der")
    cert = (checkout / "np03j-manager-cert.der").read_bytes()
    require(0 < len(cert) <= 1024, "Manager certificate exceeds the kernel's accepted size")


def manager_metadata(lock_path, checkout, output):
    lock, checkout, output = load_lock(lock_path), Path(checkout), Path(output)
    apks = list((checkout / "manager/app/build/outputs/apk/release").glob("*.apk"))
    require(len(apks) == 1, "Expected exactly one signed spoofed release APK")
    apk = apks[0]
    tools = read_json(checkout / "np03j-toolchain.json")
    sdk_root = Path(os.environ.get("ANDROID_HOME", os.environ.get("ANDROID_SDK_ROOT", "")))
    build_tools = sdk_root / "build-tools" / tools["build_tools"]
    verified = run(build_tools / "apksigner", "verify", "--verbose", "--print-certs", apk, capture=True)
    cert = (checkout / "np03j-manager-cert.der").read_bytes()
    signer = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)", verified)
    require([s.lower() for s in signer] == [digest(cert)], "APK signer does not match the certificate exported for kernel trust")
    require("Verified using v2 scheme (APK Signature Scheme v2): true" in verified,
            "Kernel manager verification requires an APK v2 signature")
    badging = run(build_tools / "aapt", "dump", "badging", apk, capture=True)
    pkg = re.search(r"package: name='([^']+)' versionCode='(\d+)'", badging)
    require(pkg and pkg[1] == lock["profile"]["manager_package"], "APK application ID drifted")
    require(int(pkg[2]) == lock["manager_version_code"], "APK version code is not the locked official revision")
    require(re.search(r"versionName='[^']+-spoofed'", badging), "Manager is not the spoofed variant")
    with zipfile.ZipFile(apk) as z:
        native = [x for x in z.namelist() if x.startswith("lib/") and x.endswith(".so")]
        require(native and all(x.startswith("lib/arm64-v8a/") for x in native), "Unexpected APK architecture")
        require("lib/arm64-v8a/libksud.so" in native, "APK lacks the source-built ksud")
    output.mkdir(parents=True, exist_ok=True)
    target = output / "NP03J-Manager-Spoofed.apk"
    shutil.copy2(apk, target)
    shutil.copy2(checkout / "np03j-manager-cert.der", output / "manager-cert.der")
    version_name = re.search(r"versionName='([^']+)'", badging)[1]
    require(version_name == lock["official_describe"] + "-spoofed", "Manager source description mismatch")
    write_json(output / "manager-identity.json", {
        "package": pkg[1], "version_code": int(pkg[2]), "official_sha": lock["sources"]["official"]["sha"],
        "uapi_version": lock["uapi_version"], "certificate_sha256": digest(cert),
        "certificate_size": len(cert), "apk_sha256": digest(target.read_bytes()),
        "version_name": version_name,
        "architecture": "arm64-v8a", "root_mode": "built-in", "lkm_payloads": False,
    })


def patch_root_kbuild(text, identity, official_sha):
    require(SHA.fullmatch(official_sha), "Invalid official base")
    require(re.fullmatch(r"[0-9a-f]{64}", identity["certificate_sha256"]), "Invalid certificate hash")
    require(0 < identity["certificate_size"] <= 1024, "Invalid certificate size")
    require(re.fullmatch(r"[a-z]{8}\.[a-z]{8}\.[a-z]{8}", identity["package"]), "Invalid package")
    require("KSU_NEXT_MANAGER_LIST" in text and "KSU_MANAGER_PACKAGE" in text,
            "Root certificate configuration changed")
    text, count = re.subn(r"^BASE_COMMIT := .*$", "BASE_COMMIT := " + official_sha, text, flags=re.M)
    require(count == 1, "Root version-base derivation changed")
    # Kleaf can stage source trees without their .git metadata. Pin the version
    # calculated from the *full official history*, never the fork's extra commits
    # or Kbuild's fallback value of 1.
    require(isinstance(identity["version_code"], int) and identity["version_code"] > 30000, "Invalid manager version")
    version_name = identity["version_name"].removesuffix("-spoofed")
    require(re.fullmatch(r"[A-Za-z0-9._+-]+", version_name), "Invalid source version name")
    anchor = "# Calculate version if git version is available"
    require(text.count(anchor) == 1, "Root version calculation changed")
    text = text.replace(anchor, f"KSU_GIT_VERSION := {identity['version_code'] - 30000}\n"
                        f"KSU_GIT_TAG := {version_name}\nKSU_GIT_VERSION_VALID := 1\n\n" + anchor)
    prefix = ("# NP03J: exact official base + one persistent manager certificate.\n"
              f"KSU_NEXT_MANAGER_LIST := {identity['certificate_size']}:{identity['certificate_sha256']}\n"
              f"KSU_MANAGER_PACKAGE := {identity['package']}\n")
    return prefix + text


def integrate_root(lock_path, identity_path, kernel):
    lock, identity, kernel = load_lock(lock_path), read_json(identity_path), Path(kernel).resolve()
    official = lock["sources"]["official"]["sha"]
    require(identity["official_sha"] == official and identity["uapi_version"] == lock["uapi_version"],
            "Manager artifact and locked root sources differ")
    require(identity["package"] == lock["profile"]["manager_package"], "Manager package mismatch")
    require(identity["version_code"] == lock["manager_version_code"] and
            identity["version_name"] == lock["official_describe"] + "-spoofed", "Manager source version mismatch")
    cert = (Path(identity_path).parent / "manager-cert.der").read_bytes()
    require(len(cert) == identity["certificate_size"] and digest(cert) == identity["certificate_sha256"],
            "Manager certificate and root trust metadata differ")
    checkout = kernel / "KernelSU-Next"
    clone_at(lock["sources"]["official"]["url"], official, checkout, full=True)
    run("git", "fetch", "--no-tags", lock["sources"]["root"]["url"], lock["sources"]["root"]["sha"], cwd=checkout)
    run("git", "checkout", "--detach", lock["sources"]["root"]["sha"], cwd=checkout)
    run("git", "merge-base", "--is-ancestor", official, "HEAD", cwd=checkout)
    require(uapi_version((checkout / "uapi/supercall.h").read_text()) == identity["uapi_version"], "Root UAPI mismatch")
    require(run("git", "rev-parse", f"{official}:uapi", cwd=checkout, capture=True).strip() ==
            run("git", "rev-parse", "HEAD:uapi", cwd=checkout, capture=True).strip(), "UAPI tree mismatch")
    kbuild = checkout / "kernel/Kbuild"
    kbuild.write_text(patch_root_kbuild(kbuild.read_text(), identity, official))
    drivers = kernel / "common/drivers"
    require(not (drivers / "kernelsu").exists(), "Unexpected existing root integration")
    (drivers / "kernelsu").symlink_to(os.path.relpath(checkout / "kernel", drivers))
    with (drivers / "Makefile").open("a") as f:
        f.write("\nobj-$(CONFIG_KSU) += kernelsu/\n")
    with (drivers / "Kconfig").open("a") as f:
        f.write('\nsource "drivers/kernelsu/Kconfig"\n')


def integrate_susfs(lock_path, kernel):
    lock, kernel = load_lock(lock_path), Path(kernel).resolve()
    source = lock["sources"]["susfs"]
    checkout = kernel / "susfs4ksu"
    clone_at(source["url"], source["sha"], checkout)
    fixes = SUSFS_FIXES
    run("git", "fetch", "--no-tags", "https://gitlab.com/pershoot/susfs4ksu.git", *fixes, cwd=checkout)
    run("git", "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "cherry-pick", *fixes, cwd=checkout)
    common = kernel / "common"
    for directory in ("fs", "include/linux"):
        for path in (checkout / "kernel_patches" / directory).iterdir():
            require(path.is_file(), "Unexpected SUSFS patch payload")
            shutil.copy2(path, common / directory / path.name)
    patch = checkout / "kernel_patches/50_add_susfs_in_gki-android14-6.1.patch"
    # Current upstream already matches current LTS. The generic action's old
    # temporary header deletions now conflict with this patch. Do not run them.
    args = ("patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", patch)
    run(*args, "--dry-run", cwd=common)
    run(*args, cwd=common)
    mm = common / "fs/proc/task_mmu.c"
    text = mm.read_text()
    if "VMA_PAD_START(" in text and not re.search(r"#include <linux/pgsize_migration(_inline)?\.h>|#define VMA_PAD_START", text):
        mm.write_text("#ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif\n" + text)
    write_json(kernel / "np03j-susfs-integration.json", {"base": source["sha"], "compatibility_fixes": fixes,
                                                        "patch_sha256": digest(patch.read_bytes())})


def set_config(path, values):
    path = Path(path)
    text = path.read_text()
    for key, value in values.items():
        line = f"CONFIG_{key}={value}" if value != "n" else f"# CONFIG_{key} is not set"
        pattern = rf"^(?:CONFIG_{key}=.*|# CONFIG_{key} is not set)$"
        if re.search(pattern, text, re.M):
            text = re.sub(pattern, line, text, flags=re.M)
        else:
            text += "\n" + line
    path.write_text(text.rstrip() + "\n")


def configure_kernel(kernel):
    kernel = Path(kernel)
    common = kernel / "common"
    config = common / "arch/arm64/configs/gki_defconfig"
    values = {key: "y" for key in REQUIRED_CONFIG}
    values.update({"ARM64_16K_PAGES": "n", "ARM64_64K_PAGES": "n", "KSU_DEBUG": "n",
                   "KSU_DISABLE_MANAGER": "n", "KSU_DISABLE_POLICY": "n", "KSU_CONTAINER_COMPAT": "n"})
    set_config(config, values)
    security = common / "security/Kconfig"
    text = security.read_text()
    marker = re.search(r"(?ms)^config LSM\n.*?(?=^config |\Z)", text)
    require(marker, "Cannot locate the LSM configuration block")
    block = re.sub(r'(default\s+"[^"\n]*selinux)(?!,baseband_guard)', r'\1,baseband_guard', marker[0])
    require("baseband_guard" in block, "Baseband Guard missing from LSM defaults")
    security.write_text(text[:marker.start()] + block + text[marker.end():])
    text = config.read_text()
    m = re.search(r'^CONFIG_LSM="([^"]+)"$', text, re.M)
    if m and "baseband_guard" not in m[1].split(","):
        set_config(config, {"LSM": '"' + m[1] + ',baseband_guard"'})
    # Record the untouched module-version checking implementation for verification after patching.
    version_file = common / "kernel/module/version.c"
    require(version_file.is_file(), "Missing 6.1 module version implementation")
    upstream = run("git", "show", "HEAD:kernel/module/version.c", cwd=common, capture=True)
    verify_module_versions(version_file.read_text(), upstream)


def verify_module_versions(actual, upstream):
    require(actual == upstream, "Module version-checking code differs from the locked upstream")
    require(re.search(r"bad_version:.*?return 0;", actual, re.S), "Module version checks are bypassed")


def verify_config(text):
    for key in REQUIRED_CONFIG:
        require(re.search(rf"^CONFIG_{key}=y$", text, re.M), f"Missing final CONFIG_{key}=y")
    require(not re.search(r"^CONFIG_ARM64_(16K|64K)_PAGES=y$", text, re.M), "Wrong final page size")
    require(not re.search(r"^CONFIG_KSU_DEBUG=y$", text, re.M), "Unexpected KSU debug build")
    require(not re.search(r"^CONFIG_KSU_(DISABLE_MANAGER|DISABLE_POLICY|CONTAINER_COMPAT)=y$", text, re.M),
            "Manager or app policy disabled, or container compatibility selected")
    lsm = re.search(r'^CONFIG_LSM="([^"]+)"$', text, re.M)
    require(lsm and "baseband_guard" in lsm[1].split(","), "BBG is compiled but not selected as an active LSM")


def verify_image(data, identity):
    require(len(data) > 4096 and data[56:60] == b"ARM\x64", "Not an uncompressed ARM64 kernel Image")
    flags = struct.unpack_from("<Q", data, 24)[0]
    require((flags >> 1) & 3 == 1, "ARM64 Image header does not specify 4K pages")
    require(identity["certificate_sha256"].encode() in data, "Manager trust hash missing from compiled Image")
    require(identity["package"].encode() in data, "Manager package restriction missing from compiled Image")
    require(b"susfs" in data and b"baseband_guard" in data, "Required compiled features missing")


def verify_arm64_elf(data):
    require(len(data) >= 64 and data[:6] == b"\x7fELF\x02\x01" and
            struct.unpack_from("<H", data, 18)[0] == 183, "Not a little-endian ARM64 ELF64 payload")


def collect_kernel(lock_path, identity_path, kernel, output):
    lock, identity = load_lock(lock_path), read_json(identity_path)
    kernel, output = Path(kernel).resolve(), Path(output).resolve()
    candidates = [kernel / "bazel-bin/common/kernel_aarch64/Image", Path("/home/runner/out/dist/Image")]
    image = next((x for x in candidates if x.is_file()), None)
    require(image, "Compiled Image not found")
    configs = [kernel / "bazel-bin/common/kernel_aarch64_config/out_dir/.config", Path("/home/runner/out/.config")]
    if not any(x.is_file() for x in configs):
        configs += list((kernel / "bazel-bin/common").rglob(".config"))
    configs = [x for x in configs if x.is_file()]
    require(configs, "Actual generated .config missing; /proc/config.gz is not an acceptable substitute")
    config = configs[0].read_text()
    verify_config(config)
    data = image.read_bytes()
    verify_image(data, identity)
    rejects = list((kernel / "common").rglob("*.rej"))
    require(not rejects, f"Patch rejects remain: {rejects}")
    makefile = (kernel / "common/Makefile").read_text()
    sublevel = re.search(r"^SUBLEVEL\s*=\s*(\d+)$", makefile, re.M)[1]
    generations = []
    for path in (kernel / "common/build.config.constants", kernel / "common/build.config.common"):
        if path.exists():
            generations += re.findall(r"^KMI_GENERATION=['\"]?(\d+)", path.read_text(), re.M)
    require(generations and len(set(generations)) == 1, "Cannot determine source KMI generation")
    kmi = "6.1-android14-" + generations[0]
    require(kmi == lock["profile"]["device_kmi"], "Compiled source KMI differs from the device profile")
    versions = re.findall(rb"Linux version ([^\x00\n]+)", data)
    require(versions, "Compiled kernel version string missing")
    release = versions[0].decode(errors="replace").split()[0]
    require(re.match(rf"^6\.1\.{sublevel}-android14-{generations[0]}(?:-|$)", release),
            "Compiled kernel lost its source KMI generation")
    require("Wild" not in release, "Unexpected kernel branding")
    output.mkdir(parents=True, exist_ok=True)
    (output / "Image").write_bytes(data)
    (output / "actual-build.config").write_text(config)
    shutil.copy2(kernel / "np03j-resolved-manifest.xml", output / "resolved-manifest.xml")
    shutil.copy2(kernel / "np03j-susfs-integration.json", output / "susfs-integration.json")
    write_json(output / "kernel-metadata.json", {"device": "NP03J", "kernel_release": release,
        "sublevel": int(sublevel), "kmi": kmi, "page_size": 4096, "image_sha256": digest(data),
        "source_lock_sha256": digest(Path(lock_path).read_bytes()), "uapi_version": lock["uapi_version"],
        "manager_certificate_sha256": identity["certificate_sha256"],
        "manager_version_code": identity["version_code"], "manager_package": identity["package"],
        "device_boot_verified": False, "detector_results_verified": False})


def zip_tree(source, destination):
    source = Path(source)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in sorted(source.rglob("*")):
            if path.is_file() and ".git" not in path.relative_to(source).parts:
                z.write(path, path.relative_to(source))


def assemble(lock_path, kernel_artifacts, manager_artifacts, output):
    lock = load_lock(lock_path)
    kdir, mdir, output = Path(kernel_artifacts), Path(manager_artifacts), Path(output)
    output.mkdir(parents=True, exist_ok=True)
    identity, meta = read_json(mdir / "manager-identity.json"), read_json(kdir / "kernel-metadata.json")
    require(meta["device"] == lock["profile"]["device"] and meta["page_size"] == 4096 and
            meta["kmi"] == lock["profile"]["device_kmi"], "Kernel device profile mismatch")
    require(meta["manager_certificate_sha256"] == identity["certificate_sha256"] and
            meta["uapi_version"] == identity["uapi_version"] and
            meta["manager_version_code"] == identity["version_code"] and
            meta["manager_package"] == identity["package"], "Kernel/manager artifact mismatch")
    require(meta["source_lock_sha256"] == digest(Path(lock_path).read_bytes()), "Kernel source lock mismatch")
    require(digest((mdir / "NP03J-Manager-Spoofed.apk").read_bytes()) == identity["apk_sha256"], "APK digest mismatch")
    require(digest((kdir / "Image").read_bytes()) == meta["image_sha256"], "Kernel Image digest mismatch")
    require(identity["package"] == lock["profile"]["manager_package"] and
            identity["version_code"] == lock["manager_version_code"] and
            identity["official_sha"] == lock["sources"]["official"]["sha"] and
            identity["uapi_version"] == lock["uapi_version"], "Manager source-lock mismatch")
    cert = (mdir / "manager-cert.der").read_bytes()
    require(digest(cert) == identity["certificate_sha256"] and len(cert) == identity["certificate_size"],
            "Public certificate artifact mismatch")
    verify_config((kdir / "actual-build.config").read_text())
    verify_image((kdir / "Image").read_bytes(), identity)
    with zipfile.ZipFile(mdir / "NoMount-NP03J-Builtin.zip") as z:
        require(z.read("NOMOUNT_SOURCE_COMMIT").decode().strip() == lock["sources"]["nomount"]["sha"],
                "NoMount module and kernel driver sources differ")
        require("bin/nm-arm64" in z.namelist() and "customize.sh" in z.namelist(), "Incomplete NoMount module")
        require(not any(n.endswith(".ko") or "lkmloader" in n for n in z.namelist()), "Unexpected loadable driver payload")
        verify_arm64_elf(z.read("bin/nm-arm64"))
        require(z.read("customize.sh") == (ROOT / ".github/np03j/nomount-customize.sh").read_bytes(),
                "NoMount installer is not the built-in-only installer")
        require(re.search(rb"^versionCode=\d+$", z.read("module.prop"), re.M), "NoMount module version code is missing")
    susfs = read_json(kdir / "susfs-integration.json")
    require(susfs["base"] == lock["sources"]["susfs"]["sha"] and
            susfs["compatibility_fixes"] == list(SUSFS_FIXES), "SUSFS integration source mismatch")
    ak = output.parent / "anykernel-package"
    clone_at(lock["sources"]["anykernel"]["url"], lock["sources"]["anykernel"]["sha"], ak)
    for name in ("tools/ak3-core.sh", "tools/busybox", "tools/magiskboot", "META-INF/com/google/android/update-binary"):
        require((ak / name).is_file() and (ak / name).stat().st_size > 0, f"Incomplete AnyKernel3 base: {name}")
    shutil.rmtree(ak / ".git")
    for name in (".github",):
        shutil.rmtree(ak / name, ignore_errors=True)
    shutil.copy2(ROOT / ".github/np03j/anykernel.sh", ak / "anykernel.sh")
    (ak / "anykernel.sh").chmod(0o755)
    shutil.copy2(kdir / "Image", ak / "Image")
    zip_tree(ak, output / f"NP03J-6.1.{meta['sublevel']}-LTS-4K-AnyKernel3.zip")
    for name in ("NP03J-Manager-Spoofed.apk", "manager-identity.json", "manager-cert.der", "NoMount-NP03J-Builtin.zip"):
        shutil.copy2(mdir / name, output / name)
    for name in ("actual-build.config", "kernel-metadata.json", "resolved-manifest.xml", "susfs-integration.json"):
        shutil.copy2(kdir / name, output / name)
    shutil.copy2(lock_path, output / "source-lock.json")
    write_json(output / "build-manifest.json", {"profile": lock["profile"], "kernel": meta,
                                               "manager": identity, "validation": "build-only; no device run"})
    checksum = "".join(f"{digest(p.read_bytes())}  {p.name}\n" for p in sorted(output.iterdir()) if p.is_file())
    (output / "SHA256SUMS").write_text(checksum)
    notes = (f"# NP03J 6.1.{meta['sublevel']} Android LTS / 4K\n\n"
             f"- Kernel: `{meta['kernel_release']}`\n"
             f"- Official KernelSU-Next: `{lock['sources']['official']['sha']}`\n"
             f"- SUSFS root integration: `{lock['sources']['root']['sha']}`\n"
             f"- SUSFS: `{lock['sources']['susfs']['sha']}`\n"
             f"- Manager: fixed spoofed identity, version {identity['version_code']}, UAPI {identity['uapi_version']}\n"
             "- Built-in KernelSU-Next, full SUSFS, built-in NoMount, Baseband Guard.\n"
             "- No restored/saved build cache, no symbol-version bypass, no kernel branding.\n"
             "- Install the matching manager and kernel as one release. The NoMount ZIP requires this built-in kernel.\n"
             "- Compilation/packaging checks only. Device boot and detector outcomes are not validated by this workflow.\n")
    (output.parent / "release-notes.md").write_text(notes)


def main():
    parser = argparse.ArgumentParser()
    subs = parser.add_subparsers(dest="command", required=True)
    for name, args in {"resolve": ("output", "workspace"), "sync-kernel": ("lock", "kernel"),
                       "prepare-manager": ("lock", "checkout"), "decode-signing": ("checkout",),
                       "manager-metadata": ("lock", "checkout", "output"),
                       "integrate-root": ("lock", "identity", "kernel"), "configure-kernel": ("kernel",),
                       "integrate-susfs": ("lock", "kernel"),
                       "collect-kernel": ("lock", "identity", "kernel", "output"),
                       "assemble": ("lock", "kernel_artifacts", "manager_artifacts", "output")}.items():
        sub = subs.add_parser(name)
        for arg in args:
            sub.add_argument(arg)
    args = vars(parser.parse_args())
    command = args.pop("command").replace("-", "_")
    globals()[command](*args.values())


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"::error::NP03J build stopped: {exc}", file=sys.stderr)
        sys.exit(1)
