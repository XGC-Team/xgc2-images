#!/usr/bin/env python3
"""Offline install check only: never starts ROS, simulation, a driver or an Agent task."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path('/usr/local/share/xgc2/full-image')
payload = json.loads((root/'payload.json').read_text())
inputs = json.loads((root/'inputs.json').read_text())
components = set(inputs['components'].split(','))
ros = 'melodic' if 'bionic' in inputs['profile'] else 'noetic'
required = ['/usr/lib/xgc2/xgc-agent']
if 'xsim' in components:
    required += ['/opt/xgc2/xsim/bin/xsim', '/usr/lib/xgc2-sensing/libxgc2-sensing-gpu.so']
if 'adapter' in components:
    adapter = 'xgc_px4_multirotor_ros1_adapter' if inputs['profile'] == 'fs150-focal-noetic' else 'xgc_ugv_ros1_adapter'
    required += ['/opt/ros/'+ros+'/lib/'+adapter+'/'+adapter+'_node']
if 'controller' in components:
    controller = 'px4_multirotor_controller' if inputs['profile'] == 'fs150-focal-noetic' else ('mecanum_ugv_controller' if inputs['profile'] == 'wheeltec-bionic-melodic' else 'unicycle_ugv_controller')
    required += ['/opt/ros/'+ros+'/lib/'+controller+'/'+controller+'_node']
for name in required:
    if not Path(name).is_file():
        raise SystemExit('Selected source component is missing: '+name)

for name, digest in payload['files'].items():
    path = Path(name)
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise SystemExit('Installed payload differs: '+name)
for name in payload['elf']:
    result = subprocess.run(['ldd', name], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    if 'not found' in result.stdout:
        raise SystemExit('Missing runtime dependency: '+name+'\n'+result.stdout)
    if result.returncode and 'not a dynamic executable' not in result.stdout and 'statically linked' not in result.stdout:
        raise SystemExit('Cannot inspect '+name+'\n'+result.stdout)
subprocess.run(['/usr/lib/xgc2/xgc-agent', '--version'], check=True)
if Path('/opt/xgc2/xsim/bin/xsim').exists():
    subprocess.run(['/opt/xgc2/xsim/bin/xsim', '--help'], check=True, stdout=subprocess.DEVNULL)
print('Verified source payload and ELF dependencies; no robot task was started.')
