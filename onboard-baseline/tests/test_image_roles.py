import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class ImageRolesTest(unittest.TestCase):
    def test_robot_roles_publish_only_named_tags_for_both_architectures(self):
        with tempfile.NamedTemporaryFile() as output:
            env=dict(os.environ,GITHUB_REPOSITORY='XGC-Team/xgc2-images',GITHUB_OUTPUT=output.name,GITHUB_EVENT_NAME='schedule')
            subprocess.run(['ruby','scripts/detect-ci-matrices.rb','["onboard-sim-fs150-focal-noetic"]'],cwd=ROOT,env=env,check=True,capture_output=True)
            values=dict(line.split('=',1) for line in Path(output.name).read_text().splitlines())
            rows=json.loads(values['build_matrix'])['include']
            self.assertEqual({(r['target'],r['arch']) for r in rows},{('runtime','amd64'),('runtime','arm64'),('builder','amd64'),('builder','arm64')})
            self.assertTrue(all(r['version_only'] and r['version']==r['target'] for r in rows))
            manifests=json.loads(values['manifest_matrix'])['include']
            self.assertEqual({r['version'] for r in manifests},{'runtime','builder'})
            self.assertTrue(all(r['version_only'] for r in manifests))

    def test_builder_extends_runtime_and_owns_language_toolchains(self):
        text=(ROOT/'apps/onboard-sim-fs150-focal-noetic/Dockerfile').read_text()
        runtime,builder=text.split('FROM runtime AS builder')
        self.assertNotIn('onboard-baseline.sh apply',runtime)
        self.assertIn('onboard-baseline.sh apply',builder)
        self.assertIn('ONBOARD_IMAGE_ROLE=runtime',runtime)
        self.assertIn('ONBOARD_IMAGE_ROLE=builder',builder)

if __name__=='__main__':unittest.main()
