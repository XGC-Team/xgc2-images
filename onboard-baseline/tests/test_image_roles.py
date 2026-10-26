import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

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

    def test_actual_build_entry_passes_the_selected_docker_stage(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/build.yml').read_text())
        for job_name in ('build','dependent_build'):
            build=next(step for step in workflow['jobs'][job_name]['steps'] if step.get('uses','').startswith('docker/build-push-action'))
            self.assertEqual(build['with']['target'],'${{ matrix.target }}')
            tags=next(step['run'] for step in workflow['jobs'][job_name]['steps'] if step.get('id')=='tags')
            role_branch=tags.split('if [[ "${{ matrix.version_only }}" == "true" ]]; then',1)[1].split('elif',1)[0]
            self.assertNotIn(':latest',role_branch)

    def test_fs150_runtime_and_builder_share_pinned_zenoh_and_keep_glpk(self):
        app = ROOT/'apps/onboard-sim-fs150-focal-noetic'
        runtime = (app/'runtime-packages.txt').read_text().splitlines()
        builder = (app/'builder-packages.txt').read_text().splitlines()
        self.assertIn('python3-pip', runtime)
        self.assertIn('libglpk40', runtime)
        self.assertIn('libglpk-dev', builder)
        self.assertNotIn('libzmqpp4', runtime)
        self.assertNotIn('libzmqpp-dev', builder)
        dockerfile = (app/'Dockerfile').read_text()
        runtime_stage = dockerfile.split('FROM runtime AS builder')[0]
        self.assertIn('COPY apps/onboard-sim-fs150-focal-noetic/install-zenoh.sh', runtime_stage)
        self.assertIn('/opt/xgc2/onboard-baseline/install-zenoh.sh apply', runtime_stage)
        self.assertIn('/usr/local/lib/xgc2/zenoh-baseline/install-zenoh.sh', runtime_stage)
        installer = (app/'install-zenoh.sh').read_text()
        self.assertIn('4c24202c46a4d0bd836bb35fb5eae77d47decbe9/requirements-runtime.txt', installer)
        self.assertIn('2e1db99fe83c9ac36a6bc38b046fa1f989dcfb05566f5ed5ba488ead337626b0', installer)
        self.assertIn('deaf32dcd9ab821e359cd8330786bcd077604b5c5730c0b096eda46f95c24a2d', installer)
        self.assertIn('76781bbfa61fdc1e9626a03202c7dd8fd103f34761dc7b94b5a2d99f5aae629e', installer)
        self.assertIn('0f142a36241e50eb3b86f9c3b0149138d2d1d7b6dd2038589fe4c62e12e776ea', installer)
        check = (app/'check-image.sh').read_text()
        self.assertIn('import rospy, zenoh', check)
        self.assertIn('install-zenoh.sh check', check)
        self.assertNotIn('libzmqpp', check)

    def test_builder_extends_runtime_and_owns_language_toolchains(self):
        text=(ROOT/'apps/onboard-sim-fs150-focal-noetic/Dockerfile').read_text()
        runtime,builder=text.split('FROM runtime AS builder')
        self.assertNotIn('onboard-baseline.sh apply',runtime)
        self.assertIn('onboard-baseline.sh apply',builder)
        self.assertIn('ONBOARD_IMAGE_ROLE=runtime',runtime)
        self.assertIn('ONBOARD_IMAGE_ROLE=builder',builder)

if __name__=='__main__':unittest.main()
