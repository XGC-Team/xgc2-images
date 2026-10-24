"""Source selection and promotion behavior without Docker or network access."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[1]/'full/build.py'
spec = importlib.util.spec_from_file_location('robot_full', FILE)
full = importlib.util.module_from_spec(spec)
spec.loader.exec_module(full)

class FullImageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root/'products/xgc2'
        self.repo.mkdir(parents=True)
        subprocess.run(['git','init','-q',str(self.repo)], check=True)
        (self.repo/'core-xgc').mkdir()
        self.source = self.repo/'core-xgc/main.go'
        self.source.write_text('original')
        (self.repo/'.gitignore').write_text('core-xgc/cache/\n')
        self.patcher = patch.object(full, 'SOURCES', ['xgc2'])
        self.patcher.start()
        self.addCleanup(self.patcher.stop)

    def test_changed_content_with_preserved_mtime_invalidates_compiler_cache(self):
        spec = importlib.util.spec_from_file_location('normalize_sources', FILE.parent/'normalize-inputs.py')
        normalize = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(normalize)
        state = self.root/'source-state.json'
        normalize.normalize(self.repo, state)
        first = self.source.stat().st_mtime_ns
        normalize.normalize(self.repo, state)
        self.assertEqual(first, self.source.stat().st_mtime_ns)
        self.source.write_text('changed content')
        os.utime(self.source, ns=(first, first))
        normalize.normalize(self.repo, state)
        self.assertGreater(self.source.stat().st_mtime_ns, first)

    def test_first_party_go_modules_cannot_fall_back_to_published_cache(self):
        spec = importlib.util.spec_from_file_location('verify_go_sources', FILE.parent/'verify-go-sources.py')
        check = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(check)
        check.verify([{'Path':'github.com/XGC-Team/runtime','Main':True,'Dir':str(self.repo)}], self.root)
        check.verify([{'Path':'example.com/thirdparty','Dir':'/module-cache'}], self.root)
        with self.assertRaises(ValueError):
            check.verify([{'Path':'github.com/XGC-Team/runtime','Dir':'/module-cache'}], self.root)
        with self.assertRaises(ValueError):
            check.verify([{'Path':'github.com/XGC-Team/runtime','Main':True,'Dir':'/module-cache'}], self.root)

    def args(self):
        return ['fs150-focal-noetic','--devops-root',str(self.root),'--cache-dir',str(self.root/'cache'),'--components','agent']

    def test_snapshot_tracks_uncommitted_sources_and_ignores_caches(self):
        first = full.snapshot(self.root)
        self.source.write_text('edited without committing')
        second = full.snapshot(self.root)
        self.assertNotEqual(first, second)
        cache = self.repo/'core-xgc/cache'
        cache.mkdir()
        (cache/'build.o').write_text('not a source')
        self.assertEqual(second, full.snapshot(self.root))
        self.source.unlink()
        self.assertNotEqual(second, full.snapshot(self.root))

    def test_plan_for_all_profiles_has_no_docker_side_effect(self):
        for profile in full.PROFILES:
            with self.subTest(profile=profile), patch.object(full, 'run') as run:
                self.assertEqual(full.main([profile,'--devops-root',str(self.root),'--plan']), 0)
                run.assert_not_called()

    def execute_build(self, fail_at=None):
        commands = []
        def run(argv, **kwargs):
            argv = [str(x) for x in argv]
            commands.append(argv)
            if fail_at and fail_at in argv:
                raise subprocess.CalledProcessError(1, argv)
            if argv[:3] == ['docker','buildx','build']:
                Path(argv[argv.index('--iidfile')+1]).write_text('sha256:'+'a'*64)
        with patch.object(full, 'run', side_effect=run), patch.object(full, 'resolve_image', return_value=('example@sha256:'+'b'*64,'sha256:'+'c'*64)), patch.object(full, 'inspect_optional', return_value=None):
            if fail_at:
                with self.assertRaises(subprocess.CalledProcessError):
                    full.main(self.args())
            else:
                self.assertEqual(full.main(self.args()), 0)
        return commands

    def test_failed_build_or_verification_never_promotes(self):
        for failure in ('buildx','run'):
            with self.subTest(failure=failure):
                commands = self.execute_build(failure)
                self.assertFalse(any(c[:2]==['docker','tag'] for c in commands))

    def test_promotion_is_last_after_offline_candidate_verification(self):
        commands = self.execute_build()
        self.assertEqual(commands[-1][:2], ['docker','tag'])
        self.assertIn('--network', commands[-2])
        self.assertIn('none', commands[-2])
        self.assertEqual(commands[-1][-1], 'onboard-sim-fs150-focal-noetic:full')
        receipt = json.loads((self.root/'cache/fs150-focal-noetic-amd64.json').read_text())
        self.assertEqual(receipt['imageId'], 'sha256:'+'a'*64)

if __name__ == '__main__':
    unittest.main()
