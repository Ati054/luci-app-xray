#!/usr/bin/env python3
import gzip
import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER_SCRIPT = os.path.join(ROOT_DIR, 'tests', 'ci', 'extract_openwrt_apk.py')

def make_padded_gzip_tar(members, pad_to_512=True):
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode='w') as t:
        for name, data, mode, linkname, entry_type in members:
            ti = tarfile.TarInfo(name)
            ti.mode = mode
            if entry_type is not None:
                ti.type = entry_type
            if linkname:
                ti.linkname = linkname
            if data is not None:
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
            else:
                t.addfile(ti)
    raw_tar = bio.getvalue()
    gzipped = gzip.compress(raw_tar)
    if pad_to_512:
        pad_len = (512 - (len(gzipped) % 512)) % 512
        gzipped += b'\x00' * pad_len
    return gzipped

class TestExtractOpenWrtApk(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.apk_path = os.path.join(self.temp_dir, 'test.apk')
        self.dest_dir = os.path.join(self.temp_dir, 'dest')
        os.makedirs(self.dest_dir, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.temp_dir, ignore_errors=True)

    def run_extractor(self, apk_path, dest_dir, *extra_args):
        cmd = [sys.executable, HELPER_SCRIPT, apk_path, dest_dir] + list(extra_args)
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        return proc

    def test_01_valid_multi_stream_apk_with_padding_and_leading_slashes(self):
        control_stream = make_padded_gzip_tar([
            ('.PKGINFO', b'pkgname = luci-app-xray\npkgver = 3.7.1-5\n', 0o644, None, tarfile.REGTYPE)
        ], pad_to_512=True)

        data_stream = make_padded_gzip_tar([
            ('/etc/init.d/xray_core', b'#!/bin/sh\nUSE_PROCD=1\n', 0o755, None, tarfile.REGTYPE),
            ('/etc/init.d/xray_profiles', b'#!/bin/sh\nUSE_PROCD=1\n', 0o755, None, tarfile.REGTYPE),
            ('/usr/share/xray/gen_config.uc', b'// ucode generator\n', 0o644, None, tarfile.REGTYPE),
            ('/usr/share/xray/gen_config.mjs', b'export default {};\n', 0o644, None, tarfile.REGTYPE),
            ('/usr/share/xray/relative_link', None, 0o777, 'gen_config.uc', tarfile.SYMTYPE),
        ], pad_to_512=True)

        with open(self.apk_path, 'wb') as f:
            f.write(control_stream + data_stream)

        res = self.run_extractor(self.apk_path, self.dest_dir)
        self.assertEqual(res.returncode, 0, f'Extractor failed: {res.stderr}')

        # Verify extracted files exist strictly under dest_dir with normalized paths
        f1 = os.path.join(self.dest_dir, 'etc', 'init.d', 'xray_core')
        f2 = os.path.join(self.dest_dir, 'etc', 'init.d', 'xray_profiles')
        f3 = os.path.join(self.dest_dir, 'usr', 'share', 'xray', 'gen_config.uc')
        f4 = os.path.join(self.dest_dir, 'usr', 'share', 'xray', 'gen_config.mjs')

        self.assertTrue(os.path.isfile(f1), f'Missing {f1}')
        self.assertTrue(os.path.isfile(f2), f'Missing {f2}')
        self.assertTrue(os.path.isfile(f3), f'Missing {f3}')
        self.assertTrue(os.path.isfile(f4), f'Missing {f4}')

        # Verify executable permissions on POSIX
        if os.name == 'posix':
            st1 = os.stat(f1)
            self.assertTrue(bool(st1.st_mode & stat.S_IXUSR), f'{f1} should be executable')

    def test_02_rejection_of_path_traversal_attempts(self):
        outside_marker = os.path.join(self.temp_dir, 'outside-marker.txt')
        data_stream = make_padded_gzip_tar([
            ('../../outside-marker.txt', b'ATTACK\n', 0o644, None, tarfile.REGTYPE),
            ('/etc/init.d/xray_core', b'#!/bin/sh\n', 0o755, None, tarfile.REGTYPE),
        ], pad_to_512=True)

        with open(self.apk_path, 'wb') as f:
            f.write(data_stream)

        res = self.run_extractor(self.apk_path, self.dest_dir)
        self.assertFalse(os.path.exists(outside_marker), 'Traversal file was written outside destination!')

    def test_03_rejection_of_escaping_symlinks(self):
        data_stream = make_padded_gzip_tar([
            ('/usr/share/bad_link', None, 0o777, '../../../../../../etc/passwd', tarfile.SYMTYPE),
            ('/etc/init.d/xray_core', b'#!/bin/sh\n', 0o755, None, tarfile.REGTYPE),
        ], pad_to_512=True)

        with open(self.apk_path, 'wb') as f:
            f.write(data_stream)

        res = self.run_extractor(self.apk_path, self.dest_dir)
        bad_link_path = os.path.join(self.dest_dir, 'usr', 'share', 'bad_link')
        # If link was created, it must not allow reading outside target
        if os.path.islink(bad_link_path):
            target = os.readlink(bad_link_path)
            self.assertFalse(target.startswith('/etc/passwd'))

    def test_04_rejection_of_malformed_corrupted_or_empty_inputs(self):
        # Empty file
        empty_apk = os.path.join(self.temp_dir, 'empty.apk')
        with open(empty_apk, 'wb') as f:
            pass
        res = self.run_extractor(empty_apk, self.dest_dir)
        self.assertNotEqual(res.returncode, 0, 'Empty APK should exit nonzero')

        # Corrupted non-gzip file
        corrupt_apk = os.path.join(self.temp_dir, 'corrupt.apk')
        with open(corrupt_apk, 'wb') as f:
            f.write(b'GARBAGE_NOT_GZIP_CONTENT')
        res = self.run_extractor(corrupt_apk, self.dest_dir)
        self.assertNotEqual(res.returncode, 0, 'Corrupt APK should exit nonzero')

        # Missing file
        missing_apk = os.path.join(self.temp_dir, 'does_not_exist.apk')
        res = self.run_extractor(missing_apk, self.dest_dir)
        self.assertNotEqual(res.returncode, 0, 'Missing APK should exit nonzero')

    def test_05_rejection_of_invalid_arguments(self):
        # Missing destination argument
        proc = subprocess.run([sys.executable, HELPER_SCRIPT, self.apk_path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(proc.returncode, 0)

        # Extra unexpected argument
        proc = subprocess.run([sys.executable, HELPER_SCRIPT, self.apk_path, self.dest_dir, 'extra_arg'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(proc.returncode, 0)

    def test_06_source_code_regression_checks(self):
        self.assertTrue(os.path.isfile(HELPER_SCRIPT), f'Helper script {HELPER_SCRIPT} must exist')
        with open(HELPER_SCRIPT, 'r', encoding='utf-8') as f:
            src = f.read()

        self.assertNotIn('exec(textwrap', src, 'Helper must not contain nested exec(textwrap)')
        self.assertNotIn('python3 -c', src, 'Helper must not invoke python3 -c')
        self.assertIn('bytes.fromhex', src, 'Helper must define GZIP_MAGIC via bytes.fromhex')

if __name__ == '__main__':
    unittest.main()
