"""Six adversarial passes: two per review round, with offline negative cases."""
import copy
import importlib.util
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / '.github/np03j'))
import np03j as m
import publish


def identity():
    return {'package': m.locked_profile()['manager_package'], 'certificate_sha256': 'b' * 64,
            'certificate_size': 700, 'version_code': 33405, 'version_name': 'v3.2.0-4-g1234567-spoofed',
            'official_sha': 'a' * 40, 'uapi_version': 6}


def config():
    return '\n'.join('CONFIG_' + k + '=y' for k in m.REQUIRED_CONFIG) + '\nCONFIG_LSM="selinux,bpf,baseband_guard"\n'


def image():
    data = bytearray(5000)
    struct.pack_into('<Q', data, 24, 2)
    data[56:60] = b'ARM\x64'
    marker = ('0x2bc:' + identity()['certificate_sha256'] + '\x00' + identity()['package'] + ' susfs baseband_guard').encode()
    data[100:100 + len(marker)] = marker
    return data


def fake_lock():
    return {'profile': m.locked_profile(), 'profile_sha256': m.digest(m.PROFILE.read_bytes()),
            'sources': {k: {'url': url, 'ref': ref, 'sha': 'a' * 40} for k, (url, ref) in m.REPOS.items()},
            'projects': [{'name': 'kernel/common', 'path': 'common', 'sha': 'a' * 40,
                          'url': 'https://android.googlesource.com/kernel/common'},
                         {'name': 'kernel/build', 'path': 'build/kernel', 'sha': 'c' * 40,
                          'url': 'https://android.googlesource.com/kernel/build'}],
            'manager_version_code': 33405, 'uapi_version': 6}


class Round1Pass1Workflow(unittest.TestCase):
    def test_fixed_profile_rejects_changed_security_and_build_choices(self):
        profile = m.locked_profile()
        changes = {'allow_version_mismatch': True, 'use_cache': True, 'page_size': '16k',
                   'brand_name': 'Wild', 'keep_kmi': False, 'commit_mode': 'verified',
                   'use_susfs': False, 'use_nomount': False, 'use_bbg': False,
                   'use_net': True, 'use_bpf': True}
        for key, value in changes.items():
            changed = dict(profile, **{key: value})
            with self.subTest(key=key), patch.object(m, 'read_json', return_value=changed), self.assertRaises(RuntimeError):
                m.locked_profile()

    def test_manual_entry_pinned_actions_and_private_key_cleanup(self):
        workflow = (ROOT / '.github/workflows/np03j-6.1-lts.yml').read_text()
        self.assertIn('  workflow_dispatch:', workflow)
        self.assertNotRegex(workflow, re.compile(r'^  (push|schedule|workflow_run|pull_request):', re.M))
        for action in re.findall(r'uses: ([^\s#]+)', workflow):
            if not action.startswith('./'):
                self.assertRegex(action, r'^[^@]+@[0-9a-f]{40}$')
        self.assertNotIn('actions/cache', workflow)
        self.assertIn('name: Remove private signing material\n        if: always()', workflow)
        self.assertIn('path: manager-artifacts/', workflow)
        self.assertNotIn('path: manager-source/', workflow)

    def test_android_setup_does_not_request_the_retired_tools_package(self):
        workflow = (ROOT / '.github/workflows/np03j-6.1-lts.yml').read_text()
        setup = re.search(r'      - uses: android-actions/setup-android@[^\n]+\n((?:        [^\n]*\n)+)', workflow)
        self.assertIsNotNone(setup)
        packages = re.search(r'^          packages: (.+)$', setup.group(1), re.M)
        self.assertIsNotNone(packages)
        self.assertEqual(packages.group(1).split(), ['platform-tools'])


class Round1Pass2Sources(unittest.TestCase):
    def test_locked_manifest_rejects_repository_and_path_substitution(self):
        cases = []
        changed = fake_lock(); changed['sources']['root']['url'] = 'https://example.invalid/root'; cases.append(changed)
        changed = fake_lock(); changed['projects'][0]['path'] = '../outside'; cases.append(changed)
        changed = fake_lock(); changed['projects'][1]['path'] = 'common'; cases.append(changed)
        changed = fake_lock(); changed['sources']['susfs']['sha'] = 'dev'; cases.append(changed)
        changed = fake_lock(); changed['profile_sha256'] = '0' * 64; cases.append(changed)
        for changed in cases:
            with tempfile.TemporaryDirectory() as temp:
                lock = Path(temp) / 'lock.json'; m.write_json(lock, changed)
                with self.assertRaises(RuntimeError): m.load_lock(lock)

    def test_uapi_must_be_unique_and_numeric(self):
        self.assertEqual(m.uapi_version('const unsigned int KERNEL_SU_UAPI_VERSION = 6;'), 6)
        for text in ('', 'KERNEL_SU_UAPI_VERSION = -1;', 'KERNEL_SU_UAPI_VERSION = 6; KERNEL_SU_UAPI_VERSION = 7;'):
            with self.subTest(text=text), self.assertRaises(RuntimeError): m.uapi_version(text)


class Round2Pass1Trust(unittest.TestCase):
    SOURCE = ('BASE_COMMIT := old\n# Calculate version if git version is available\n'
              'ifndef KSU_NEXT_MANAGER_LIST\nKSU_NEXT_MANAGER_LIST := official\nendif\n'
              'ifdef KSU_MANAGER_PACKAGE\nendif\n')

    def test_exact_custom_certificate_package_and_official_version_are_injected(self):
        value = identity()
        result = m.patch_root_kbuild(self.SOURCE, value, value['official_sha'])
        self.assertTrue(result.startswith('# NP03J:'))
        self.assertIn('KSU_NEXT_MANAGER_LIST := 0x2bc:' + 'b' * 64, result)
        self.assertIn('KSU_MANAGER_PACKAGE := ' + value['package'], result)
        self.assertIn('KSU_GIT_VERSION := 3405', result)
        self.assertIn('KSU_GIT_VERSION_VALID := 1', result)

    def test_certificate_size_roundtrips_through_the_kernel_c_hex_parser(self):
        # Use the consumer's C sscanf format so the old decimal writer fails.
        source = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv) {
    unsigned int size = 0;
    char hash[65] = {0};
    if (argc != 4) return 2;
    return !(sscanf(argv[1], "%x:%64[^,]", &size, hash) == 2 &&
             size == strtoul(argv[2], NULL, 10) && strcmp(hash, argv[3]) == 0);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / 'parser.c').write_text(source)
            subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(path / 'parser.c'),
                            '-o', str(path / 'parser')], check=True, capture_output=True)
            for size in (1, 9, 10, 255, 256, 700, 730, 1024):
                with self.subTest(size=size):
                    value = dict(identity(), certificate_size=size)
                    result = m.patch_root_kbuild(self.SOURCE, value, value['official_sha'])
                    entry = re.search(r'^KSU_NEXT_MANAGER_LIST := (.+)$', result, re.M)[1]
                    subprocess.run([str(path / 'parser'), entry, str(size), 'b' * 64], check=True)
            old = subprocess.run([str(path / 'parser'), '730:' + 'b' * 64, '730', 'b' * 64])
            self.assertNotEqual(old.returncode, 0)

    def test_upstream_size_parser_changes_require_audit(self):
        consumer = 'if (sscanf(p, "%x:%64[^,]", &size, hash) == 2) {}'
        m.verify_manager_size_parser(consumer)
        for changed in (consumer.replace('%x:', '%u:'), consumer.replace('%x:', '%i:'), ''):
            with self.subTest(source=changed), self.assertRaises(RuntimeError):
                m.verify_manager_size_parser(changed)

    def test_malformed_identity_or_changed_source_fails(self):
        for key, bad in (('certificate_sha256', 'x' * 64), ('certificate_size', 1025),
                         ('package', 'com.invalid;touch'), ('version_code', 1), ('version_name', '$(shell false)')):
            value = dict(identity(), **{key: bad})
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                m.patch_root_kbuild(self.SOURCE, value, 'a' * 40)
        with self.assertRaises(RuntimeError):
            m.patch_root_kbuild(self.SOURCE.replace('BASE_COMMIT := old', ''), identity(), 'a' * 40)


class Round2Pass2CompiledKernel(unittest.TestCase):
    def test_missing_features_inactive_bbg_debug_and_wrong_pages_fail(self):
        m.verify_config(config())
        mutations = [config().replace('CONFIG_' + key + '=y', '# CONFIG_' + key + ' is not set')
                     for key in m.REQUIRED_CONFIG]
        mutations += [config().replace(',baseband_guard', ''), config() + 'CONFIG_ARM64_16K_PAGES=y\n',
                      config() + 'CONFIG_KSU_DEBUG=y\n', config() + 'CONFIG_KSU_DISABLE_MANAGER=y\n']
        for text in mutations:
            with self.subTest(text=text[-100:]), self.assertRaises(RuntimeError): m.verify_config(text)

    def test_real_image_header_and_embedded_manager_trust_are_required(self):
        m.verify_image(image(), identity())
        wrong = bytearray(image()); struct.pack_into('<Q', wrong, 24, 4)
        for data in (bytes(5000), wrong, image().replace(b'b' * 64, b'c' * 64), image().replace(b'susfs', b'xxxxx')):
            with self.assertRaises(RuntimeError): m.verify_image(data, identity())

    def test_correct_hash_with_wrong_certificate_length_is_rejected(self):
        for wrong in (b'700:', b'0x700:', b'0x2bd:'):
            data = image().replace(b'0x2bc:', wrong)
            with self.subTest(entry=wrong), self.assertRaises(RuntimeError):
                m.verify_image(data, identity())
        unterminated = image().replace(('b' * 64 + '\x00').encode(), ('b' * 64 + ',').encode())
        with self.assertRaises(RuntimeError):
            m.verify_image(unterminated, identity())

    def test_early_return_bypass_is_rejected_even_with_original_bad_version_label(self):
        upstream = 'int check_version(void) {\n /* body */\nbad_version:\nreturn 0;\n}\n'
        m.verify_module_versions(upstream, upstream)
        bypass = upstream.replace('/* body */', 'return 1; /* body */')
        with self.assertRaises(RuntimeError): m.verify_module_versions(bypass, upstream)


class Round3Pass1Installer(unittest.TestCase):
    def test_device_guard_and_builtin_only_module(self):
        installer = (ROOT / '.github/np03j/anykernel.sh').read_text()
        guard = installer[installer.index('np03j_match=false'):installer.index('split_boot')]
        self.assertIn("$np03j_match || abort", guard)
        self.assertIn('NP03J|PQ83P01', guard)
        self.assertNotRegex(guard, r'pineapple\)')
        self.assertIn('is_slot_device=1', installer)
        module = (ROOT / '.github/np03j/nomount-customize.sh').read_text()
        self.assertIn('"$MODPATH/bin/nm" version', module)
        self.assertNotRegex(module, r'\b(insmod|modprobe)\b')

    def test_wrong_architecture_cli_fails(self):
        elf = bytearray(64); elf[:6] = b'\x7fELF\x02\x01'; struct.pack_into('<H', elf, 18, 183)
        m.verify_arm64_elf(elf)
        struct.pack_into('<H', elf, 18, 62)
        with self.assertRaises(RuntimeError): m.verify_arm64_elf(elf)


class Round3Pass2Publication(unittest.TestCase):
    def test_full_packaging_and_cross_artifact_mutations(self):
        def prepare(temp):
            base = Path(temp); kdir = base / 'kernel'; mdir = base / 'manager'
            kdir.mkdir(); mdir.mkdir()
            lock = fake_lock(); lock_path = base / 'lock.json'; m.write_json(lock_path, lock)
            cert = b'public test certificate'; apk = b'fake APK for artifact binding only'
            ident = dict(identity(), certificate_sha256=m.digest(cert), certificate_size=len(cert), apk_sha256=m.digest(apk))
            data = bytes(image()).replace(b'0x2bc:' + b'b' * 64,
                                        f"{len(cert):#x}:{ident['certificate_sha256']}".encode())
            meta = {'device': 'NP03J', 'page_size': 4096, 'kmi': '6.1-android14-11', 'sublevel': 177,
                    'kernel_release': '6.1.177-android14-11-g1234567', 'uapi_version': 6,
                    'manager_certificate_sha256': ident['certificate_sha256'], 'manager_package': ident['package'],
                    'manager_version_code': ident['version_code'], 'source_lock_sha256': m.digest(lock_path.read_bytes()),
                    'image_sha256': m.digest(data)}
            m.write_json(mdir / 'manager-identity.json', ident); m.write_json(kdir / 'kernel-metadata.json', meta)
            (mdir / 'manager-cert.der').write_bytes(cert); (mdir / 'NP03J-Manager-Spoofed.apk').write_bytes(apk)
            (kdir / 'Image').write_bytes(data); (kdir / 'actual-build.config').write_text(config())
            (kdir / 'resolved-manifest.xml').write_text('<manifest/>')
            m.write_json(kdir / 'susfs-integration.json', {'base': 'a' * 40, 'compatibility_fixes': list(m.SUSFS_FIXES)})
            elf = bytearray(64); elf[:6] = b'\x7fELF\x02\x01'; struct.pack_into('<H', elf, 18, 183)
            with zipfile.ZipFile(mdir / 'NoMount-NP03J-Builtin.zip', 'w') as z:
                z.writestr('NOMOUNT_SOURCE_COMMIT', 'a' * 40)
                z.writestr('bin/nm-arm64', elf)
                z.writestr('customize.sh', (ROOT / '.github/np03j/nomount-customize.sh').read_bytes())
                z.writestr('module.prop', 'id=nomount\nversionCode=1\n')
            return lock_path, kdir, mdir, base / 'release'

        def fake_anykernel(url, sha, destination):
            destination.mkdir(); (destination / '.git').mkdir()
            for name in ('tools/ak3-core.sh', 'tools/busybox', 'tools/magiskboot', 'META-INF/com/google/android/update-binary'):
                path = destination / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('fixture')

        with tempfile.TemporaryDirectory() as temp:
            args = prepare(temp)
            with patch.object(m, 'clone_at', side_effect=fake_anykernel): m.assemble(*args)
            self.assertEqual(len(list(args[3].iterdir())), 12)
            self.assertTrue((args[3] / 'SHA256SUMS').is_file())
            for p in args[3].iterdir(): self.assertNotIn(p.suffix, ('.p12', '.jks'))

        for target in ('Image', 'APK', 'cert', 'pair', 'nomount'):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                args = prepare(temp); _, kdir, mdir, _ = args
                if target == 'Image': (kdir / 'Image').write_bytes(b'wrong image')
                if target == 'APK': (mdir / 'NP03J-Manager-Spoofed.apk').write_bytes(b'wrong APK')
                if target == 'cert': (mdir / 'manager-cert.der').write_bytes(b'wrong certificate')
                if target == 'pair':
                    meta = m.read_json(kdir / 'kernel-metadata.json'); meta['manager_version_code'] += 1
                    m.write_json(kdir / 'kernel-metadata.json', meta)
                if target == 'nomount':
                    with zipfile.ZipFile(mdir / 'NoMount-NP03J-Builtin.zip', 'a') as z: z.writestr('nomount.ko', b'wrong driver')
                with self.assertRaises(RuntimeError), patch.object(m, 'clone_at') as network:
                    m.assemble(*args)
                network.assert_not_called()

    def test_signer_changes_package_changes_and_downgrades_are_rejected(self):
        original = identity()
        publish.check_previous(original, original)
        publish.check_previous(original, dict(original, version_code=33406))
        for key, value in (('package', 'newpackage.newother.newthird'), ('certificate_sha256', 'c' * 64),
                           ('certificate_size', 701), ('version_code', 33404)):
            with self.subTest(key=key), self.assertRaises(RuntimeError):
                publish.check_previous(original, dict(original, **{key: value}))

    def test_release_is_drafted_until_all_assets_upload(self):
        source = (ROOT / '.github/np03j/publish.py').read_text()
        self.assertLess(source.index("'--draft'"), source.index("'upload'"))
        self.assertLess(source.index("'upload'"), source.index("'--draft=false'"))
        self.assertNotIn('--clobber', source)
        self.assertNotIn('--prerelease=true', source)


if __name__ == '__main__':
    unittest.main()
