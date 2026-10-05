import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent / 'cil/setup-vm.sh'
BRANCH = 'integration-20261005-sr'


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inputs = self.root / 'inputs'
        self.inputs.mkdir()
        self.destination = self.root / 'monza'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'runtime.log'
        self.env = dict(os.environ, SR_VM_ROOT=str(self.destination),
                        SR_TEST_LOG=str(self.log), PATH=str(self.bin) + ':' + os.environ['PATH'],
                        GIT_AUTHOR_NAME='Tyler Baker', GIT_COMMITTER_NAME='Tyler Baker',
                        GIT_AUTHOR_EMAIL='tyler.baker@oss.qualcomm.com',
                        GIT_COMMITTER_EMAIL='tyler.baker@oss.qualcomm.com')
        self.stub('docker', '''#!/bin/bash
printf '%s\\n' "$*" >> "$SR_TEST_LOG"
if [ -n "${SR_TEST_FAIL:-}" ] && [ "${*: -2}" = "build $SR_TEST_FAIL" ]; then
    exit 23
fi
''')
        self.stub('sudo', '''#!/bin/bash
if [ "$1" = systemctl ]; then exit 0; fi
exec "$@"
''')

    def stub(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output(['git', *args], env=self.env, text=True, input='',
                                       stderr=subprocess.DEVNULL).strip()

    def bundles(self, build_branch=BRANCH):
        repo = self.root / 'source'
        self.git('init', '-q', str(repo))
        tree = self.git('-C', str(repo), 'mktree')
        revision = self.git('-C', str(repo), 'commit-tree', tree, '-m',
                            'test: fixture: provide a source bundle\n\nSigned-off-by: Tyler Baker <tyler.baker@oss.qualcomm.com>')
        for project, branch in [('qcom-manifest', 'all-boards'), ('qcom-buildroot', build_branch)]:
            self.git('-C', str(repo), 'update-ref', 'refs/heads/' + branch, revision)
            self.git('-C', str(repo), 'bundle', 'create', str(self.inputs / (project + '.bundle')), branch)
        (self.inputs / 'bundles').mkdir()
        (self.inputs / 'bundles/component.bundle').write_bytes((self.inputs / 'qcom-buildroot.bundle').read_bytes())
        return revision

    def run_setup(self):
        return subprocess.run(['bash', str(SCRIPT), str(self.inputs)], env=self.env,
                              text=True, capture_output=True)

    def test_missing_input_does_not_provision(self):
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing input: qcom-manifest.bundle', result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.destination.exists())

    def test_wrong_branch_does_not_provision(self):
        self.bundles(build_branch='wrong-branch')
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('build bundle lacks ' + BRANCH, result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.destination.exists())

    def test_sources_are_imported_and_staged(self):
        revision = self.bundles()
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        for project, branch in [('qcom-manifest', 'ventuno-q'), ('qcom-buildroot', BRANCH)]:
            actual = self.git('-C', str(self.destination / f'qb-git/{project}.git'), 'rev-parse', branch)
            self.assertEqual(actual, revision)
        self.assertEqual((self.destination / 'sr/bundles/component.bundle').read_bytes(),
                         (self.inputs / 'bundles/component.bundle').read_bytes())
        self.assertEqual((self.destination / 'sr/build.sh').read_bytes(),
                         (SCRIPT.parent.parent / 'build.sh').read_bytes())
        self.assertIn('SystemReady CIL environment ready', result.stdout)

    def test_failed_container_layer_stops_setup(self):
        self.bundles()
        self.env['SR_TEST_FAIL'] = 'video'
        result = self.run_setup()
        self.assertEqual(result.returncode, 23)
        self.assertNotIn('environment ready', result.stdout)
        self.assertNotIn('build npu', self.log.read_text())


if __name__ == '__main__':
    unittest.main()
