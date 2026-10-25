"""Exercise actual workflow context-selection steps without downloading releases."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WorkflowContextTest(unittest.TestCase):
    def test_all_workflow_callers_use_the_selected_consumer_manifest(self):
        expected = {
            'onboard-sim-fs150-focal-noetic': json.loads((ROOT/'onboard-baseline/tool-scripts.json').read_text())['context'],
            'xgc2-latex-toolchain': json.loads((ROOT/'tool-scripts.json').read_text())['context'],
        }
        steps = []
        for name in ('build.yml', 'reusable-build-images.yml'):
            raw = subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
                'puts JSON.generate(YAML.load_file(ARGV[0]))', str(ROOT/'.github/workflows'/name)], text=True)
            for job in json.loads(raw)['jobs'].values():
                steps += [(name, step['run']) for step in job.get('steps', []) if step.get('id') == 'tool-scripts']
        self.assertEqual(len(steps), 3)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            shim = directory/'python3'
            shim.write_text('#!/bin/sh\nexec '+shlex.quote(sys.executable)+' "$@" --url-only\n')
            shim.chmod(0o755)
            output = directory/'output'
            for name, run in steps:
                for app, url in expected.items():
                    with self.subTest(workflow=name, app=app):
                        output.write_text('')
                        command = run.replace('${{ matrix.app }}', app)
                        subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', command], cwd=ROOT,
                                       env=dict(os.environ, PATH=str(directory)+':'+os.environ['PATH'],
                                                GITHUB_OUTPUT=str(output)), check=True)
                        self.assertEqual(output.read_text().strip(), 'context='+url)


if __name__ == '__main__':
    unittest.main()
