#!/usr/bin/env python3
"""Explicit local source composition. No publication or container lifecycle changes."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
IMAGES = HERE.parents[1]
PROFILES = json.loads((HERE.parent / 'baselines.json').read_text())['profiles']
# Provider locations, not dependency versions. Product CMake/Go manifests and
# product-owned source entrypoints validate and build their actual dependencies.
SOURCES = [
    'common/math', 'common/state-machine', 'common/chassis-hold', 'common/xrpc',
    'common/protobuf', 'common/agent-runtime', 'common/storage', 'common/acados',
    'ros1/common/ros1-msgs', 'ros1/common/ros1-utils',
    'ros1/communication/ros1-adapter', 'ros1/simulator/xsim',
    'ros1/simulator/gazebo-sim/fs150-sitl',
    'ros1/controller/ugv-controller', 'ros1/controller/multirotor-controller',
    'ros1/perception/estimator/hover-thrust', 'xgc2',
]
XGC_PATHS = ('core-xgc/', 'scripts/', 'packaging/', 'VERSION')


def run(argv, **kwargs):
    print('+ '+ ' '.join(str(x) for x in argv), flush=True)
    return subprocess.run([str(x) for x in argv], check=True, **kwargs)


def capture(argv):
    return subprocess.check_output([str(x) for x in argv], universal_newlines=True).strip()


def files_in(root, source):
    repo = root / 'products' / source
    if not (repo / '.git').exists():
        raise ValueError('Initialize the existing product checkout: '+str(repo))
    names = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split(b'\0')
    for raw in sorted(set(names)):
        if not raw:
            continue
        name = os.fsdecode(raw)
        if source == 'xgc2' and not any(name == p or name.startswith(p) for p in XGC_PATHS):
            continue
        path = repo / name
        if path.is_dir() and not path.is_symlink():
            raise ValueError('Source contains a nested checkout needing an explicit provider: '+str(path))
        if not path.exists() and not path.is_symlink():
            continue  # Local source deletion is part of the input snapshot.
        yield path, Path('products') / source / name


def snapshot(root, destination=None):
    records = {}
    for source in SOURCES:
        for path, relative in files_in(root, source):
            mode = stat.S_IMODE(path.lstat().st_mode)
            if path.is_symlink():
                link = os.readlink(path)
                if os.path.isabs(link):
                    raise ValueError('Use a relative source symlink: '+str(path))
                try:
                    (path.parent / link).resolve().relative_to(root.resolve())
                except ValueError:
                    raise ValueError('Source symlink escapes the DevOps checkout: '+str(path))
                value = 'link:'+link
                if destination:
                    target = destination / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.symlink_to(link)
            else:
                data = path.read_bytes()
                value = hashlib.sha256(data).hexdigest()
                if destination:
                    target = destination / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                    target.chmod(mode)
                    shutil.copystat(path, target)
            records[relative.as_posix()] = [mode, value]
    digest = hashlib.sha256(json.dumps(records, sort_keys=True).encode()).hexdigest()
    return digest


def resolve_image(reference, platform, pull=True):
    cached = inspect_optional(reference)
    if pull or cached is None or cached.get('Architecture') != platform.split('/')[-1]:
        run(['docker', 'pull', '--platform', platform, reference])
    info = json.loads(capture(['docker', 'image', 'inspect', reference]))[0]
    expected = platform.split('/')[-1]
    if info['Os'] != 'linux' or info['Architecture'] != expected:
        raise ValueError('Pulled image does not match '+platform)
    repository = reference.rsplit(':', 1)[0]
    candidates = [x for x in info.get('RepoDigests', []) if x.startswith(repository+'@sha256:')]
    if not candidates:
        raise ValueError('Pull did not provide an immutable repository digest: '+reference)
    return candidates[0], info['Id']


def inspect_optional(reference):
    result = subprocess.run(['docker', 'image', 'inspect', reference], universal_newlines=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return json.loads(result.stdout)[0] if result.returncode == 0 else None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', choices=sorted(PROFILES))
    parser.add_argument('--devops-root', type=Path, default=IMAGES.parent.parent)
    parser.add_argument('--platform', choices=['linux/amd64', 'linux/arm64'], default='linux/'+('arm64' if os.uname().machine in ('aarch64', 'arm64') else 'amd64'))
    parser.add_argument('--components', default='agent,xsim,adapter,controller', help='comma-separated agent,xsim,adapter,controller; agent is required')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--builder-image', help='override the toolchain image declared by xgc2-images; robot base always pulls latest')
    parser.add_argument('--cache-dir', type=Path, default=Path(os.environ.get('XDG_CACHE_HOME', str(Path.home()/'.cache')))/'xgc2/robot-full')
    parser.add_argument('--plan', action='store_true', help='inspect local inputs only; no pull, build, tag or container operation')
    parser.add_argument('--rebuild', action='store_true', help='build even if the existing full input receipt matches')
    args = parser.parse_args(argv)
    selected = set(args.components.split(','))
    if not selected <= {'agent', 'xsim', 'adapter', 'controller'} or 'agent' not in selected or args.jobs < 1:
        parser.error('select valid components including agent, and a positive --jobs')
    # Adapter metadata declares XSim; source providers remain from one snapshot.
    if 'adapter' in selected:
        selected.add('xsim')
    components = ','.join(sorted(selected))
    root = args.devops_root.resolve()
    profile = PROFILES[args.profile]
    repository = 'ghcr.io/xgc-team/xgc2-images/'
    base = repository+'onboard-sim-'+args.profile+':latest'
    builder_key = 'xgc2-build-'+profile['ubuntuCodename']+'-full-'+profile['rosDistro']
    metadata = (IMAGES/'apps'/builder_key/'app.yml').read_text()
    builder = args.builder_image or next(line.split(':',1)[1].strip() for line in metadata.splitlines() if line.startswith('image:'))
    full = 'onboard-sim-'+args.profile+':full'
    source_digest = snapshot(root)
    plan = {'profile': args.profile, 'platform': args.platform, 'base': base, 'builder': builder, 'output': full, 'components': components, 'sourceDigest': source_digest}
    print(json.dumps(plan, indent=2), flush=True)
    if args.plan:
        return 0
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    # One stable full tag per profile, including when callers select different architectures.
    with (args.cache_dir/(args.profile+'.lock')).open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        base_pin, base_id = resolve_image(base, args.platform)
        builder_pin, builder_id = resolve_image(builder, args.platform, pull=False)
        recipe = hashlib.sha256()
        for path in sorted(HERE.iterdir()):
            if path.is_file():
                recipe.update(path.name.encode()+path.read_bytes())
        inputs = dict(plan, baseDigest=base_pin, baseImageId=base_id, builderDigest=builder_pin, builderImageId=builder_id, recipe=recipe.hexdigest())
        identity = hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()
        existing = inspect_optional(full)
        if existing and not args.rebuild and (existing['Config'].get('Labels') or {}).get('org.xgc2.robot-full.input') == identity:
            print('Current full already matches the pulled base and local source snapshot: '+existing['Id'])
            return 0
        with tempfile.TemporaryDirectory(prefix=args.profile+'-', dir=args.cache_dir) as temp:
            context = Path(temp)
            source = context/'source'
            source.mkdir()
            copied = snapshot(root, source)
            if copied != source_digest or snapshot(root) != copied:
                raise ValueError('Local sources changed while snapshotting; previous full is preserved. Retry when the edit completes.')
            shutil.copytree(HERE, context/'recipe', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
            (context/'inputs.json').write_text(json.dumps(inputs, sort_keys=True)+'\n')
            shutil.copyfile(HERE/'Dockerfile', context/'Dockerfile')
            iid = context/'image-id'
            run(['docker', 'buildx', 'build', '--load', '--platform', args.platform,
                 '--build-arg', 'BASE_IMAGE='+base_pin, '--build-arg', 'BUILD_IMAGE='+builder_pin,
                 '--build-arg', 'BUILD_CACHE_ID='+builder_id.split(':')[-1][:16],
                 '--build-arg', 'PROFILE='+args.profile, '--build-arg', 'FULL_COMPONENTS='+components,
                 '--build-arg', 'BUILD_JOBS='+str(args.jobs), '--build-arg', 'INPUT_ID='+identity,
                 '--iidfile', iid, context])
            candidate = iid.read_text().strip()
            if not candidate.startswith('sha256:'):
                raise ValueError('Build did not return a canonical image ID; full was not changed.')
            run(['docker', 'run', '--rm', '--network', 'none', '--read-only', '--tmpfs', '/tmp:rw,nosuid,nodev',
                 '--entrypoint', '/usr/bin/python3', candidate, '/usr/local/share/xgc2/full-image/verify.py'])
            receipt = args.cache_dir/(args.profile+'-'+args.platform.split('/')[-1]+'.json')
            receipt.write_text(json.dumps(dict(inputs, imageId=candidate, inputId=identity), indent=2)+'\n')
            # Mutation of the actual-use tag is the last step, after offline validation.
            run(['docker', 'tag', candidate, full])
            print('Ready: '+full+' ('+candidate+'). Existing robot containers were not changed.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print('full-image: '+str(error)+'; previous full tag is preserved.', file=sys.stderr)
        sys.exit(1)
