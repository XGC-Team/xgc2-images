"""Release extraction must work without executing scripts or trusting tar paths."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/tool-scripts-context.py'
spec = importlib.util.spec_from_file_location('tool_context', SCRIPT)
context = importlib.util.module_from_spec(spec)
spec.loader.exec_module(context)


def bundle(extra=None):
    stream = io.BytesIO()
    names = ['onboard-baseline/baselines.json', 'onboard-baseline/onboard-baseline.sh',
             'scripts/build/install-toolchains.sh', 'scripts/build/install-ros-apt-source.sh']
    with tarfile.open(fileobj=stream, mode='w:gz') as archive:
        for name in names:
            entry = tarfile.TarInfo(name)
            entry.size = 2
            archive.addfile(entry, io.BytesIO(b'{}'))
        if extra is not None:
            archive.addfile(extra)
    return stream.getvalue()


class ContextTest(unittest.TestCase):
    def test_consumer_manifest_selects_its_own_immutable_release(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / 'robot-scripts.json'
            url = 'https://fixture/scripts/revisions/' + 'a'*40 + '/tool-scripts.tar.gz'
            lock.write_text(json.dumps({'context': url}))
            result = subprocess.run([sys.executable, str(SCRIPT), '--lock', str(lock), '--url-only'],
                                    text=True, capture_output=True, check=True)
            self.assertEqual(result.stdout.strip(), url)
            lock.write_text(json.dumps({'context': 'https://fixture/latest.tar.gz'}))
            result = subprocess.run([sys.executable, str(SCRIPT), '--lock', str(lock), '--url-only'],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_scaffolding_preserves_existing_apps_and_uses_the_selected_parent(self):
        source = SCRIPT.parent/'build/generate-build-apps.py'
        definition = importlib.util.spec_from_file_location('build_scaffold', source)
        scaffold = importlib.util.module_from_spec(definition)
        definition.loader.exec_module(scaffold)
        with tempfile.TemporaryDirectory() as directory, patch.object(scaffold, 'APPS', Path(directory)):
            existing = Path(directory)/'xgc2-build-focal-dev'
            existing.mkdir()
            (existing/'app.yml').write_text('version: 9.3.2\n')
            (existing/'Dockerfile').write_text('custom product dependencies\n')
            scaffold.write_app('focal', 'dev', None, 'ubuntu:20.04')
            self.assertEqual((existing/'Dockerfile').read_text(), 'custom product dependencies\n')
            scaffold.write_app('focal', 'ros', 'noetic', 'ubuntu:20.04')
            generated = (Path(directory)/'xgc2-build-focal-ros-noetic/Dockerfile').read_text()
            self.assertIn('xgc2-build-focal-dev:9.3.2', generated)
            self.assertIn('COPY --from=tool-scripts scripts/build/install-ros-apt-source.sh', generated)
            self.assertIn('COPY --from=tool-scripts onboard-baseline/configure-ubuntu-mirror.sh', generated)

    def test_extracts_release_once_with_executable_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'release'
            with patch.object(context, 'urlopen', return_value=io.BytesIO(bundle())) as download:
                self.assertEqual(context.materialize('https://fixture/release', destination), destination)
                self.assertEqual(context.materialize('https://fixture/release', destination), destination)
                download.assert_called_once()
            self.assertEqual((destination/'onboard-baseline/baselines.json').read_bytes(), b'{}')
            self.assertEqual((destination/'onboard-baseline/onboard-baseline.sh').stat().st_mode & 0o777, 0o755)

    def test_rejects_traversal_and_links_without_leaving_cached_release(self):
        for name, kind in [('../escape', tarfile.REGTYPE), ('/absolute', tarfile.REGTYPE),
                           ('link', tarfile.SYMTYPE), ('device', tarfile.CHRTYPE)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                destination = Path(directory) / 'release'
                entry = tarfile.TarInfo(name)
                entry.type = kind
                with patch.object(context, 'urlopen', return_value=io.BytesIO(bundle(entry))):
                    with self.assertRaises(ValueError):
                        context.materialize('https://fixture/release', destination)
                self.assertFalse(destination.exists())
                self.assertFalse((Path(directory)/'escape').exists())
