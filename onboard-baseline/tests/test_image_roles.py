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
            self.assertTrue(all(r['release_version']=='1.0.4' for r in rows))
            manifests=json.loads(values['manifest_matrix'])['include']
            self.assertEqual({r['version'] for r in manifests},{'runtime','builder'})
            self.assertTrue(all(r['version_only'] and r['release_version']=='1.0.4' for r in manifests))

    def test_actual_build_entry_passes_the_selected_docker_stage(self):
        workflow=yaml.safe_load((ROOT/'.github/workflows/build.yml').read_text())
        for job_name in ('build','dependent_build'):
            build=next(step for step in workflow['jobs'][job_name]['steps'] if step.get('uses','').startswith('docker/build-push-action'))
            self.assertEqual(build['with']['target'],'${{ matrix.target }}')
            tags=next(step['run'] for step in workflow['jobs'][job_name]['steps'] if step.get('id')=='tags')
            role_branch=tags.split('if [[ "${{ matrix.version_only }}" == "true" ]]; then',1)[1].split('elif',1)[0]
            self.assertNotIn(':latest',role_branch)
            self.assertIn('matrix.release_version', role_branch)
            self.assertIn('github.event_name', role_branch)
        for job_name in ('manifest', 'dependent_manifest'):
            publish=next(step['run'] for step in workflow['jobs'][job_name]['steps'] if step.get('name')=='Publish multi-architecture manifests' or step.get('name')=='Publish dependent multi-architecture manifests')
            self.assertIn('matrix.version }}-${{ matrix.release_version', publish)
            self.assertIn('github.event_name }}" != "schedule"', publish)

    def test_fs150_runtime_and_builder_share_pinned_zenoh_and_keep_glpk(self):
        app = ROOT/'apps/onboard-sim-fs150-focal-noetic'
        runtime = (app/'runtime-packages.txt').read_text().splitlines()
        builder = (app/'builder-packages.txt').read_text().splitlines()
        self.assertIn('python3-pip', runtime)
        self.assertIn('netbase', runtime)
        self.assertIn('chrony', runtime)
        self.assertIn('ros-noetic-mavros-extras', runtime)
        self.assertIn('libglpk40', runtime)
        self.assertIn('libglpk-dev', builder)
        self.assertNotIn('libzmqpp4', runtime)
        self.assertNotIn('libzmqpp-dev', builder)
        dockerfile = (app/'Dockerfile').read_text()
        runtime_stage = dockerfile.split('FROM runtime AS builder')[0]
        self.assertIn('org.opencontainers.image.version="1.0.4"', runtime_stage)
        self.assertIn('xgc2-zenoh=1.8.0-1~focal', runtime)
        self.assertIn('COPY --from=tool-scripts onboard-baseline/install-zenoh.sh', runtime_stage)
        self.assertNotIn('COPY apps/onboard-sim-fs150-focal-noetic/install-zenoh.sh', runtime_stage)
        self.assertIn('/opt/xgc2/onboard-baseline/install-zenoh.sh apply', runtime_stage)
        self.assertIn('/usr/local/lib/xgc2/zenoh-baseline/install-zenoh.sh', runtime_stage)
        self.assertFalse((app/'install-zenoh.sh').exists())
        import json as _json
        lock = _json.loads((app/'tool-scripts.json').read_text())['context']
        self.assertIn('1613d29d55824ce08c1b8d7039fb6ba5f22c7a1e', lock)
        self.assertIn('xgc2-zenoh', (ROOT/'onboard-baseline/assert-base-only.sh').read_text())
        check = (app/'check-image.sh').read_text()
        self.assertIn('chrony.service chronyd.service', check)
        self.assertIn('runuser -u "$ONBOARD_BASELINE_USER"', check)
        self.assertIn('check-network-databases.sh', check)
        self.assertIn('check-mavros-vision-plugin.py', check)
        self.assertIn('ldd /opt/ros/noetic/lib/libmavros_extras.so', check)
        self.assertIn('import rospy, zenoh', check)
        self.assertIn('install-zenoh.sh check', check)
        self.assertNotIn('libzmqpp', check)

    def test_fs150_guard_accepts_apt_owned_zenoh_and_still_blocks_products(self):
        guard = ROOT/'onboard-baseline/assert-base-only.sh'
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory)/'dpkg-query'
            env = dict(os.environ, PATH=directory+':'+os.environ['PATH'], ONBOARD_BASELINE_PROFILE='fs150-focal-noetic')
            fake.write_text('#!/bin/sh\nprintf "xgc2-zenoh\\tinstalled\\n"\n')
            fake.chmod(0o755)
            allowed = subprocess.run(['bash', str(guard)], env=env, capture_output=True, text=True)
            self.assertEqual(allowed.returncode, 0, allowed.stderr)
            fake.write_text('#!/bin/sh\nprintf "xgc2-product\\tinstalled\\n"\n')
            fake.chmod(0o755)
            blocked = subprocess.run(['bash', str(guard)], env=env, capture_output=True, text=True)
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn('xgc2-product', blocked.stderr)

    def test_systemd_probe_passes_checks_to_container_stdin(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp)/'docker'
            fake.write_text("#!/usr/bin/env python3\n"
                            "import os,sys\n"
                            "a=sys.argv[1:]\n"
                            "open(os.environ['DOCKER_CALLS'],'a').write(a[0]+'\\n')\n"
                            "if a[0]=='exec':\n"
                            "    assert a[1]=='-i', 'container stdin is not attached'\n"
                            "    body=sys.stdin.read()\n"
                            "    assert 'systemctl show' in body and 'CAP_SYS_TIME' in body\n"
                            "    print('fixture checks received')\n")
            fake.chmod(0o755)
            log=Path(tmp)/'calls'
            env=dict(os.environ, PATH=tmp+':'+os.environ['PATH'], DOCKER_CALLS=str(log))
            result=subprocess.run(['bash', str(ROOT/'onboard-baseline/tests/smoke-systemd-chrony.sh'),
                                   'fixture-image'], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('fixture checks received', result.stdout)
            self.assertEqual(log.read_text().splitlines(), ['run', 'exec', 'stop'])

    def test_builder_extends_runtime_and_owns_language_toolchains(self):
        text=(ROOT/'apps/onboard-sim-fs150-focal-noetic/Dockerfile').read_text()
        runtime,builder=text.split('FROM runtime AS builder')
        self.assertNotIn('onboard-baseline.sh apply',runtime)
        self.assertIn('onboard-baseline.sh apply',builder)
        self.assertIn('ONBOARD_IMAGE_ROLE=runtime',runtime)
        self.assertIn('ONBOARD_IMAGE_ROLE=builder',builder)
        self.assertIn('/opt/xgc2/onboard-baseline/disable-image-chrony.sh', runtime)
        self.assertIn('/opt/xgc2/onboard-baseline/disable-image-chrony.sh', builder)

if __name__=='__main__':unittest.main()
