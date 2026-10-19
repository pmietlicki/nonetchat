"""Publishable, source-only Apple compilation fixture. No app history or secrets.

snapshot copies an explicit allowlist into a NEW directory, without Git objects.
prepare/build verify that snapshot, then generate a disposable Flutter demo whose
only NoNetChat code is the listed Swift files. This is NOT a NoNetChat app build.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SWIFT = (
    'apple/AppleFastLanePlugin.swift',
    'ios/Runner/AppleHotspotPlugin.swift',
    'ios/Runner/AppleAwarePairing.swift',
    'ios/Runner/AppDelegate.swift',
    'ios/Runner/NotificationActions.swift',
    'macos/Runner/MainFlutterWindow.swift',
    'macos/Runner/AppDelegate.swift',
)
PUBLIC_INPUTS = SWIFT + (
    'apple/APPLE-SAMPLE-LICENSE.txt',
    'tool/ci/apple_native_ci.py',
    '.github/workflows/apple-fast-lane.yml',
)
README = '''# NoNetChat Apple native compilation fixture

This source-only repository contains the allowlisted Swift components and a
disposable Xcode/Flutter compilation harness. It has independent Git history.
It contains no NoNetChat Dart code, user data, signing material or app assets.

CI compiles the actual Swift sources against iOS 26+ and macOS SDKs, including
the gated WiFiAware code. It generates a trivial Flutter demo, NOT NoNetChat.
There is no app publication and no Windows build. No secrets are required.
These builds do not validate radios, provisioning, the full NoNetChat app or UX.
Paired WiFiAware remains disabled pending device and provisioning validation.

SOURCE.json records the source revision and each public file's SHA-256.
The included Apple sample notice applies to the adapted pairing UI.
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def snapshot(source, destination, revision):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('A full source revision is required')
    # Never merge into a pre-existing tree: it could contain private files.
    destination.mkdir(parents=True, exist_ok=False)
    for name in PUBLIC_INPUTS:
        path = source / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(source.resolve()):
            raise ValueError(f'Not a regular allowlisted source: {name}')
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    (destination / 'README.md').write_text(README, encoding='utf-8')
    files = {name: digest(destination / name) for name in (*PUBLIC_INPUTS, 'README.md')}
    manifest = {'schema': 1, 'sourceRevision': revision, 'scope': 'Apple native compilation only', 'sha256': files}
    (destination / 'SOURCE.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    verify_snapshot(destination)
    return manifest


def verify_snapshot(root):
    manifest = json.loads((root / 'SOURCE.json').read_text(encoding='utf-8'))
    expected = set(PUBLIC_INPUTS) | {'README.md'}
    if set(manifest.get('sha256', {})) != expected:
        raise ValueError('Public manifest differs from the explicit allowlist')
    if manifest.get('schema') != 1 or not re.fullmatch(r'[0-9a-f]{40}', manifest.get('sourceRevision', '')):
        raise ValueError('Invalid public provenance')
    # Ignore only the local Git database and disposable generated build output.
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*')
              if p.is_file() and p.relative_to(root).parts[0] not in ('.git', 'build')}
    if actual != expected | {'SOURCE.json'}:
        raise ValueError('Unexpected files in public snapshot')
    for name, sha in manifest['sha256'].items():
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or digest(path) != sha:
            raise ValueError(f'Public source mismatch: {name}')
    return manifest


def wire_sources(project, names):
    path = project / 'Runner.xcodeproj/project.pbxproj'
    text = path.read_text(encoding='utf-8')
    phases = list(re.finditer(r'(\w+) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;(.*?)\n\s*\};', text, re.S))
    phases = [p for p in phases if 'AppDelegate.swift in Sources' in p[2]]
    if len(phases) != 1:
        raise ValueError('Cannot identify the demo Runner source phase')
    phase_id = phases[0][1]
    for name in names:
        ref = hashlib.sha256(('native-ref:' + name).encode()).hexdigest()[:24].upper()
        build = hashlib.sha256(('native-build:' + name).encode()).hexdigest()[:24].upper()
        if ref in text or build in text:
            raise ValueError('Duplicate native source wiring')
        text = text.replace('/* End PBXBuildFile section */',
                            f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */')
        text = text.replace('/* End PBXFileReference section */',
                            f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "Runner/{name}"; sourceTree = SOURCE_ROOT; }};\n/* End PBXFileReference section */')
        pattern = r'(' + phase_id + r' /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;.*?files = \(\n)'
        text, count = re.subn(pattern, lambda m: m[1] + f'\t\t\t\t{build} /* {name} in Sources */,\n', text, count=1, flags=re.S)
        if count != 1:
            raise ValueError('Cannot add the native source to Runner')
    # Match the real app's deployment/Swift language settings.
    text = re.sub(r'IPHONEOS_DEPLOYMENT_TARGET = [^;]+;', 'IPHONEOS_DEPLOYMENT_TARGET = 15.0;', text)
    text = re.sub(r'MACOSX_DEPLOYMENT_TARGET = [^;]+;', 'MACOSX_DEPLOYMENT_TARGET = 12.0;', text)
    text = re.sub(r'SWIFT_VERSION = [^;]+;', 'SWIFT_VERSION = 5.0;', text)
    path.write_text(text, encoding='utf-8')


def prepare(root):
    manifest = verify_snapshot(root)
    target = root / 'build/apple-native-ci'
    if target.exists():
        raise ValueError('Use a fresh disposable harness directory')
    subprocess.run(['flutter', 'create', '--platforms=ios,macos', '--no-pub',
                    '--org', 'org.nonetchat.validation', '--project-name', 'nonet_apple_validation', str(target)], check=True)
    copies = {}
    for source in SWIFT:
        platforms = ('ios', 'macos') if source.startswith('apple/') else (source.split('/')[0],)
        for platform in platforms:
            destination = target / platform / 'Runner' / Path(source).name
            shutil.copyfile(root / source, destination)
            if digest(destination) != manifest['sha256'][source]:
                raise ValueError('Native source changed while preparing compilation')
            copies[destination.relative_to(target).as_posix()] = manifest['sha256'][source]
    for platform, names in {'ios': ('AppleFastLanePlugin.swift', 'AppleHotspotPlugin.swift', 'AppleAwarePairing.swift', 'NotificationActions.swift'),
                            'macos': ('AppleFastLanePlugin.swift',)}.items():
        wire_sources(target / platform, names)
        path = target / platform / 'Runner/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['NSBonjourServices'] = ['_nonet-fast._tcp']
        info['NSLocalNetworkUsageDescription'] = 'Compile-only native validation fixture.'
        if platform == 'ios':
            info['NoNetPairedAwareEnabled'] = False
            info['WiFiAwareServices'] = {'_nonet-fast._tcp': {'Publishable': {}, 'Subscribable': {}}}
        path.write_bytes(plistlib.dumps(info))
    (target / 'NATIVE-SOURCES.json').write_text(json.dumps(copies, indent=2) + '\n', encoding='utf-8')
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    snap = sub.add_parser('snapshot')
    snap.add_argument('destination', type=Path)
    snap.add_argument('--revision', required=True)
    sub.add_parser('verify')
    sub.add_parser('prepare')
    sub.add_parser('build')
    args = parser.parse_args()
    if args.command == 'snapshot':
        snapshot(ROOT, args.destination, args.revision)
        print('Created an allowlisted snapshot without Git history')
    elif args.command == 'verify':
        verify_snapshot(ROOT)
        print('Public snapshot contains only allowlisted Apple compilation files')
    else:
        target = prepare(ROOT)
        if args.command == 'build':
            subprocess.run(['flutter', 'pub', 'get'], cwd=target, check=True)
            subprocess.run(['flutter', 'build', 'ios', '--release', '--no-codesign'], cwd=target, check=True)
            subprocess.run(['flutter', 'build', 'macos', '--release'], cwd=target, check=True)
            print('Native compilation passed; full NoNetChat app and radios are NOT validated')


if __name__ == '__main__':
    main()
