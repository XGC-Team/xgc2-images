#!/usr/bin/env python3
"""Find distro runtime packages from the installed ELF closure, not a second Depends list."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET
import yaml

stage = Path('/out/rootfs')
packages = {'sudo', 'iproute2', 'procps', 'util-linux', 'python3'}
# Include logical ROS/Python runtime dependencies which have no ELF library.
# Read the selected products' own package declarations, not another package list.
ros = os.environ['ROS_DISTRO']
ros_root = Path('/opt/ros') / ros
installed_manifests = list((stage / 'opt/ros' / ros / 'share').glob('*/package.xml'))
provided = {ET.parse(p).getroot().findtext('name') for p in installed_manifests}
firstparty = {ET.parse(p).getroot().findtext('name') for p in Path('/source/products').rglob('package.xml') if '.git' not in p.parts}
for manifest in installed_manifests:
    document = ET.parse(manifest).getroot()
    for node in list(document.findall('depend')) + list(document.findall('exec_depend')) + list(document.findall('run_depend')):
        name = (node.text or '').strip()
        if name in provided:
            continue
        if name in firstparty:
            raise SystemExit('Declared ROS runtime source dependency is missing: '+name)
        if (ros_root / 'share' / name / 'package.xml').is_file():
            packages.add('ros-'+ros+'-'+name.replace('_','-'))
        elif name and not re.search(r'^(lib)?xgc2[-_]', name):
            installed = subprocess.run(['dpkg-query','-W','-f=${Status}',name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
            if installed.returncode == 0 and installed.stdout == 'install ok installed':
                packages.add(name)
if 'xsim' in os.environ['FULL_COMPONENTS'].split(','):
    metadata = yaml.safe_load(Path('/source/products/ros1/simulator/xsim/.xgc2/product.yml').read_text())
    for entry in metadata['apt'].get('depends', []):
        name = entry.split(' ', 1)[0]
        if name.startswith('ros-noetic-'):
            logical = name[len('ros-noetic-'):].replace('-','_')
            if logical in firstparty:
                if logical not in provided:
                    raise SystemExit('XSim source dependency is missing: '+logical)
            else:
                packages.add('ros-'+ros+'-'+logical.replace('_','-'))
# Agent packaging remains authoritative for its generic OS runtime dependencies.
for deb in Path('/source/products/xgc2/dist').glob('xgc2-agent_*.deb'):
    dependencies = subprocess.check_output(['dpkg-deb','-f',str(deb),'Depends'], universal_newlines=True)
    for item in dependencies.split(','):
        name = re.split(r'[ :()]', item.strip())[0]
        if name:
            packages.add(name)
elf_files = []
for path in stage.rglob('*'):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as handle:
            if handle.read(4) == b'\x7fELF':
                elf_files.append(path)
for staged in elf_files:
    installed = Path('/') / staged.relative_to(stage)
    result = subprocess.run(['ldd', str(installed)], universal_newlines=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if 'not found' in result.stdout:
        raise SystemExit('Unresolved source runtime: '+str(installed)+'\n'+result.stdout)
    if result.returncode and 'not a dynamic executable' not in result.stdout and 'statically linked' not in result.stdout:
        raise SystemExit('Cannot inspect '+str(installed)+'\n'+result.stdout)
    for match in re.finditer(r'(?:=>\s*)?(/[^\s()]+)', result.stdout):
        library = Path(match.group(1)).resolve()
        if (stage / library.relative_to('/')).exists():
            continue
        query = subprocess.run(['dpkg-query', '-S', str(library)], universal_newlines=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if query.returncode:
            # Ubuntu's merged-/usr aliases may differ from the package's recorded path.
            alias = str(library).replace('/usr/lib/', '/lib/', 1)
            query = subprocess.run(['dpkg-query', '-S', alias], universal_newlines=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if query.returncode:
            raise SystemExit('No staged artifact or distro package owns '+str(library))
        packages.add(query.stdout.split(': ', 1)[0].split(':', 1)[0])
for package in packages:
    if re.search(r'^(xsim$|xgc2-|libxgc2|ros-\w+-xgc2-)', package):
        raise SystemExit('Source closure accidentally uses a published product: '+package)
Path('/out/runtime-packages.txt').write_text('\n'.join(sorted(packages))+'\n')
# Keep a content receipt; no source checkout or build cache enters the runtime.
files = {}
for path in stage.rglob('*'):
    if path.is_file() and not path.is_symlink():
        files['/'+path.relative_to(stage).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
Path('/out/payload.json').write_text(json.dumps({'files': files, 'elf': ['/'+p.relative_to(stage).as_posix() for p in elf_files]}, sort_keys=True)+'\n')
