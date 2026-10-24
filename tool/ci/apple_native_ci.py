"""Publishable, source-only Apple compilation fixture. No app history or secrets.

snapshot copies an explicit allowlist into a NEW directory, without Git objects.
prepare/build verify that snapshot, then generate a disposable Flutter demo whose
only NoNetChat code is the listed Swift files. This is NOT a NoNetChat app build.
"""
import argparse
import hashlib
import json
import platform
import posixpath
import stat
import urllib.request
import zipfile
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
    'apple/NotificationActions.swift',
    'apple/ArrivalNotifications.swift',
    'apple/LocalMediaOwnership.swift',
    'apple/RecordingBackupPolicy.swift',
    'apple/RecordingOutputFile.swift',
    'apple/RecordingPcmQueue.swift',
    'apple/AppleRecordingRenderer.swift',
    'apple/RecordingAacWorker.swift',
    'apple/ReceivedAudioSources.swift',
    'apple/AppleReceivedAudioSources.swift',
    'apple/RegisteredPluginSource.swift',
    'apple/AppleWebRTCRegistration.swift',
    'apple/LocalMediaHost.swift',
    'apple/AppleLocalMediaPlugin.swift',
    'apple/IOSLocalMediaPresentation.swift',
    'apple/MacLocalMediaPresentation.swift',
    'macos/Runner/MainFlutterWindow.swift',
    'macos/Runner/AppDelegate.swift',
)
NATIVE_TESTS = ('tool/ci/tests/native/apple_local_media_ownership_test.swift',
                'tool/ci/tests/native/apple_local_media_host_test.swift',
                'tool/ci/tests/native/apple_recording_backup_test.swift',
                'tool/ci/tests/native/received_audio_sources_test.swift',
                'tool/ci/tests/native/registered_plugin_source_test.swift',
                'tool/ci/tests/native/recording_output_file_test.swift',
                'tool/ci/tests/native/recording_pcm_queue_test.swift',
                'tool/ci/tests/native/apple_recording_aac_test.swift',
                'tool/ci/tests/native/apple_received_audio_sdk_test.swift',
                'tool/ci/tests/native/apple_registration_fixture.swift')
PUBLIC_INPUTS = SWIFT + NATIVE_TESTS + (
    'apple/APPLE-SAMPLE-LICENSE.txt',
    'tool/ci/apple_native_ci.py',
    '.github/workflows/apple-fast-lane.yml',
)
README = '''# NoNetChat Apple native compilation fixture

This source-only repository contains the allowlisted Swift components and a
disposable Xcode/Flutter compilation harness. It has independent Git history.
It contains no NoNetChat Dart code, user data, signing material or app assets.

CI executes the shared native ownership checks, then compiles the actual Swift
sources against iOS 26+ and macOS SDKs, including
the gated WiFiAware code. It generates a trivial Flutter demo, NOT NoNetChat.
There is no app publication and no Windows build. No secrets are required.
These builds do not validate radios, provisioning, the full NoNetChat app or UX.
The disposable demo resolves flutter_webrtc 1.6.2+hotfix.4. Native source-identity
checks also link the exact WebRTC 150.7871.01 macOS framework (archive and image
hashes pinned here) and check its runtime bundle. They use receive-only peers
without SDP, a microphone, a renderer, a file or network traffic; this does not
prove received audio or recording. No application pub cache is modified.
Separate synthetic PCM checks exercise the copy-only renderer, bounded queue,
AAC worker and owned temporary files, including 16/44.1/48 kHz conversion and
positive file closure. They do not receive RTP or use a microphone, a camera,
the full NoNetChat UI, or a physical Apple device.
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
    common = tuple(Path(source).name for source in SWIFT if source.startswith('apple/'))
    registration_test = NATIVE_TESTS[-1]
    shutil.copyfile(root / registration_test, target / 'macos/Runner' / Path(registration_test).name)
    for platform, names in {'ios': common + ('AppleHotspotPlugin.swift', 'AppleAwarePairing.swift'),
                            'macos': common + (Path(registration_test).name,)}.items():
        wire_sources(target / platform, names)
        path = target / platform / 'Runner/Info.plist'
        info = plistlib.loads(path.read_bytes())
        info['NSBonjourServices'] = ['_nonet-fast._tcp']
        info['NSLocalNetworkUsageDescription'] = 'Compile-only native validation fixture.'
        if platform == 'ios':
            info['NoNetPairedAwareEnabled'] = False
            info['WiFiAwareServices'] = {'_nonet-fast._tcp': {'Publishable': {}, 'Subscribable': {}}}
        path.write_bytes(plistlib.dumps(info))
    # Both real app entrypoints above are compiled unchanged. Only this exact
    # macOS registration block is replaced in the disposable runtime fixture.
    window = target / 'macos/Runner/MainFlutterWindow.swift'
    text = window.read_text()
    registration = '''let receivedAudio = AppleWebRTCRegistration.register(in: flutterViewController) {
      RegisterGeneratedPlugins(registry: $0)
    }'''
    if text.count(registration) != 1:
        raise ValueError('Expected one generated macOS registration call')
    text = text.replace(registration, '''let receivedAudio: AppleRegisteredAudioSource?
    if ProcessInfo.processInfo.arguments.contains("--nonet-registration-fixture") {
      receivedAudio = AppleRegistrationFixture.run(registry: flutterViewController)
      DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    } else {
      receivedAudio = AppleWebRTCRegistration.register(in: flutterViewController) {
        RegisterGeneratedPlugins(registry: $0)
      }
    }''')
    window.write_text(text)
    # Generated public demo only: compile the exact dependency and deferred
    # permission settings, without copying any application Dart source.
    pubspec = target / 'pubspec.yaml'
    text = pubspec.read_text(encoding='utf-8')
    text = text.replace('dependencies:\n', 'dependencies:\n  flutter_local_notifications: 22.3.2\n  flutter_webrtc: 1.6.2+hotfix.4\n', 1)
    pubspec.write_text(text, encoding='utf-8')
    (target / 'lib/main.dart').write_text("""import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterLocalNotificationsPlugin().initialize(
    settings: const InitializationSettings(
      iOS: DarwinInitializationSettings(requestAlertPermission: false,
        requestSoundPermission: false, requestBadgePermission: false),
      macOS: DarwinInitializationSettings(requestAlertPermission: false,
        requestSoundPermission: false, requestBadgePermission: false),
    ),
    onDidReceiveNotificationResponse: (_) {},
  );
  runApp(const MaterialApp(home: Scaffold(body: Text('Native compile fixture'))));
}
""", encoding='utf-8')
    (target / 'NATIVE-SOURCES.json').write_text(json.dumps(copies, indent=2) + '\n', encoding='utf-8')
    return target


def check_media_ownership(root):
    """Execute the real Foundation-only state machine; no simulated SDK build."""
    verify_snapshot(root)
    directory = root / 'build/native-media-tests'
    directory.mkdir(parents=True, exist_ok=False)
    suites = (
        ('ownership', 'LOCAL_MEDIA_SWIFT', ('apple/LocalMediaOwnership.swift',), ('admission', 'roles', 'recording', 'clocks',
         'scopes', 'exact-account', 'reentrant-reads', 'recording-visibility')),
        ('host', 'LOCAL_MEDIA_HOST', ('apple/LocalMediaOwnership.swift', 'apple/LocalMediaHost.swift'),
         ('admission', 'roles', 'late-presentation', 'failed-presentation', 'recording',
          'late-recording', 'lost-recording-indication', 'scopes', 'late-state-removal',
          'maintenance-during-update', 'cancelled-quit', 'stop-retry')),
        ('backup', 'RECORDING_BACKUP', ('apple/RecordingBackupPolicy.swift',),
         ('scope', 'levels', 'failures', 'links', 'replacement', 'native-policy')),
        ('received-audio', 'RECEIVED_AUDIO', ('apple/ReceivedAudioSources.swift',),
         ('fresh-wrappers', 'peer-replacement', 'receiver-replacement', 'track-replacement',
          'ambiguous-or-non-audio', 'terminal-liveness', 'scope-retirement', 'two-engines',
          'reentrant-admission', 'reentrant-validation', 'lookup-and-owner-loss',
          'identifier-boundaries', 'retired-callbacks')),
        ('registered-plugin', 'REGISTERED_PLUGIN', ('apple/RegisteredPluginSource.swift',),
         ('one-instance', 'ambiguous-registration', 'publication-loss', 'registry-loss',
          'sdk-loss', 'independent-retirement', 'retire-before-registration')),
        ('recording-file', 'RECORDING_FILE', ('apple/RecordingOutputFile.swift',),
         ('owned-output', 'never-overwrite', 'file-link', 'backup-refusal',
          'marker-and-account', 'directory-replacement', 'hard-link',
          'partial-write-and-interruption', 'write-failure', 'sync-failure',
          'uncertain-close-never-retried', 'retired-during-backup', 'typed-video-name',
          'marker-tampering', 'output-truncation', 'foreign-fd-reuse-survives',
          'directory-link', 'marker-link', 'concurrent-close-drains-write')),
        ('recording-pcm', 'RECORDING_PCM', ('apple/RecordingPcmQueue.swift',),
         ('owned-copy', 'immutable-format', 'invalid-input', 'one-second-bound-and-tail',
          'block-bound', 'byte-bound', 'overflow-before-copy', 'copy-failure',
          'ring-wrap-and-retirement', 'seal-wakes-worker', 'concurrent-drain',
          'independent-owners', 'invalid-format-after-retirement')),
    )
    for index, (name, marker, extra, cases) in enumerate(suites):
        executable = directory / name
        sources = extra + (NATIVE_TESTS[index],)
        subprocess.run(['swiftc', '-swift-version', '5', '-warnings-as-errors',
                        '-strict-concurrency=complete', '-parse-as-library',
                        *(str(root / source) for source in sources), '-o', str(executable)], check=True)
        result = subprocess.run([str(executable)], capture_output=True, text=True, check=True, timeout=30)
        lines = result.stdout.splitlines()
        if (lines[:-1] != [marker + '_CASE_OK:' + case for case in cases]
                or not re.fullmatch(marker + r'_OK:[1-9][0-9]*', lines[-1])):
            raise ValueError('Native media tests did not execute every required case')
        print(result.stdout, end='')



# Same byte-exact artifact as flutter_webrtc 1.6.2+hotfix.4's Apple binary target.
APPLE_RTC_SDK_URL = 'https://github.com/webrtc-sdk/Specs/releases/download/150.7871.01/WebRTC.xcframework.zip'
APPLE_RTC_SDK_SHA256 = '03815cdf2f6a0ed328c94d74cce8fd1b8d2b6e95e2b37eab66795012fcecfdfa'
APPLE_RTC_SDK_BYTES = 69079305
APPLE_RTC_MAC_BINARY_SHA256 = 'c33685c8d823266071a4001def1cfe38a69ce9189e78625c337525220f70a47f'


def verify_sdk_members(archive):
    """Only the reviewed framework root and in-root relative links may extract."""
    from pathlib import PurePosixPath
    with zipfile.ZipFile(archive) as zipped:
        names = set()
        for member in zipped.infolist():
            path = PurePosixPath(member.filename)
            if (not path.parts or path.parts[0] != 'WebRTC.xcframework' or
                    path.is_absolute() or '..' in path.parts or '\\' in member.filename or
                    '\x00' in member.filename or member.filename in names):
                raise ValueError('Unexpected SDK archive path')
            names.add(member.filename)
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode):
                target = zipped.read(member).decode('utf-8')
                resolved = posixpath.normpath(str(path.parent / target))
                if (not target or '\x00' in target or '\\' in target or target.startswith('/') or
                        not resolved.startswith('WebRTC.xcframework/')):
                    raise ValueError('External SDK archive link')
            elif mode and not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise ValueError('Unexpected SDK archive entry')


def check_received_audio_sdk(root):
    """Execute source identity against the actual SDK; never start real media."""
    verify_snapshot(root)
    directory = root / 'build/native-received-sdk'
    directory.mkdir(parents=True, exist_ok=False)
    archive = directory / 'WebRTC.xcframework.zip'
    sha = hashlib.sha256()
    count = 0
    with urllib.request.urlopen(APPLE_RTC_SDK_URL, timeout=60) as source, archive.open('xb') as output:
        while block := source.read(64 * 1024):
            count += len(block)
            if count > APPLE_RTC_SDK_BYTES:
                raise ValueError('Unexpected SDK artifact size')
            output.write(block)
            sha.update(block)
    if count != APPLE_RTC_SDK_BYTES or sha.hexdigest() != APPLE_RTC_SDK_SHA256:
        raise ValueError('SDK artifact does not match the pinned binary target')
    verify_sdk_members(archive)
    extracted = directory / 'sdk'
    extracted.mkdir()
    # macOS ditto preserves the reviewed framework's internal version links.
    subprocess.run(['ditto', '-x', '-k', str(archive), str(extracted)], check=True)
    frameworks = extracted / 'WebRTC.xcframework/macos-arm64_x86_64'
    framework = frameworks / 'WebRTC.framework'
    if not framework.is_dir():
        raise ValueError('Pinned macOS framework absent')
    binary = framework / 'Versions/A/WebRTC'
    if digest(binary) != APPLE_RTC_MAC_BINARY_SHA256:
        raise ValueError('Extracted macOS SDK image changed')
    executable = directory / 'received-sdk'
    sources = ('apple/ReceivedAudioSources.swift', 'apple/AppleReceivedAudioSources.swift',
               'tool/ci/tests/native/apple_received_audio_sdk_test.swift')
    architecture = platform.machine()
    if architecture not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported native SDK fixture architecture')
    subprocess.run(['swiftc', '-swift-version', '5', '-warnings-as-errors',
                    '-strict-concurrency=complete', '-parse-as-library',
                    '-target', architecture + '-apple-macos12.0',
                    *(str(root / name) for name in sources), '-F', str(frameworks),
                    '-framework', 'WebRTC', '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    '-o', str(executable)], check=True)
    result = subprocess.run([str(executable), str(binary)], capture_output=True, text=True, check=True, timeout=180)
    cases = ('pinned-runtime', 'fresh-native-wrappers', 'original-track-retained', 'peer-scope', 'retirement')
    lines = result.stdout.splitlines()
    if (lines[:-1] != ['APPLE_RECEIVED_SDK_CASE_OK:' + case for case in cases] or
            not re.fullmatch(r'APPLE_RECEIVED_SDK_OK:[1-9][0-9]*', lines[-1])):
        raise ValueError('Pinned SDK source identity checks did not execute')
    print(result.stdout, end='')
    print('Pinned SDK identity passed; RTP, microphone, renderer and output NOT tested')
    return frameworks


def check_recording_aac(root, frameworks):
    """Real owned files and synthetic PCM through the actual Apple encoder/renderer."""
    directory = root / 'build/native-recording-aac'
    directory.mkdir(parents=True, exist_ok=False)
    executable = directory / 'recording-aac'
    sources = ('apple/RecordingOutputFile.swift', 'apple/RecordingPcmQueue.swift',
               'apple/AppleRecordingRenderer.swift', 'apple/RecordingAacWorker.swift',
               'tool/ci/tests/native/apple_recording_aac_test.swift')
    subprocess.run(['swiftc', '-swift-version', '5', '-warnings-as-errors',
                    '-strict-concurrency=complete', '-parse-as-library',
                    '-target', platform.machine() + '-apple-macos12.0',
                    *(str(root / name) for name in sources), '-F', str(frameworks),
                    '-framework', 'WebRTC', '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                    '-o', str(executable)], check=True)
    try:
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired as error:
        for output in (error.stdout, error.stderr):
            if output:
                print(output.decode('utf-8', errors='replace') if isinstance(output, bytes) else output, end='')
        raise
    print(result.stdout, end='')
    print(result.stderr, end='')
    cases = ('mono-16k', 'mono-48k-blocks', 'stereo-48k-blocks', 'stereo-44100-blocks',
             'no-input', 'stop-before-start', 'wrong-media-type', 'sync-failure', 'write-failure',
             'invalid-renderer-format', 'queue-overrun', 'existing-output', 'independent-workers',
             'repeated-finalization')
    lines = result.stdout.splitlines()
    if (result.returncode != 0 or
            [line for line in lines if line.startswith('APPLE_RECORDING_AAC_CASE_OK:')] !=
            ['APPLE_RECORDING_AAC_CASE_OK:' + case for case in cases] or
            sum(line.startswith('APPLE_RECORDING_AAC_MEDIA:') for line in lines) != 52 or
            not re.fullmatch(r'APPLE_RECORDING_AAC_OK:[1-9][0-9]*', lines[-1] if lines else '')):
        raise ValueError('Actual Apple recording codec cases did not all execute')
    print('Synthetic renderer/codec/file checks passed; no RTP, microphone or physical device tested')


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
        if args.command == 'build':
            check_media_ownership(ROOT)
            frameworks = check_received_audio_sdk(ROOT)
            check_recording_aac(ROOT, frameworks)
        target = prepare(ROOT)
        if args.command == 'build':
            subprocess.run(['flutter', 'pub', 'get'], cwd=target, check=True)
            subprocess.run(['flutter', 'build', 'ios', '--release', '--no-codesign'], cwd=target, check=True)
            subprocess.run(['flutter', 'build', 'macos', '--release'], cwd=target, check=True)
            binary = target / 'build/macos/Build/Products/Release/nonet_apple_validation.app/Contents/MacOS/nonet_apple_validation'
            try:
                result = subprocess.run([str(binary), '--nonet-registration-fixture'],
                                        capture_output=True, text=True, timeout=120)
            except subprocess.TimeoutExpired as error:
                # run() already stopped and joined this disposable test process.
                # Keep its exact partial trace instead of hiding the wait stage.
                for output in (error.stdout, error.stderr):
                    if output:
                        print(output.decode('utf-8', errors='replace') if isinstance(output, bytes) else output, end='')
                raise
            print(result.stdout, end='')
            print(result.stderr, end='')
            cases = ('actual-generated-registration', 'public-forwarding', 'publication-retirement',
                     'two-real-engines', 'explicit-retirement')
            lines = result.stdout.splitlines()
            if (result.returncode != 0 or
                    any('APPLE_REGISTRATION_CASE_OK:' + case not in lines for case in cases) or
                    not any(re.fullmatch(r'APPLE_REGISTRATION_OK:[1-9][0-9]*', line) for line in lines)):
                raise ValueError('Actual Apple registration runtime did not pass')
            print('Actual Flutter registration passed; no RTP, microphone, renderer or output tested')
            print('Native compilation passed; full NoNetChat app and radios are NOT validated')


if __name__ == '__main__':
    main()
