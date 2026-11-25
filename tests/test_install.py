import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'install.sh'
APP = 'tofu-eq'
UNIT = f'{APP}-filter.service'
SYSTEM_TOOLS = (
    'bash', 'cat', 'chmod', 'cp', 'dirname', 'find', 'gzip', 'head', 'mkdir',
    'mktemp', 'rm', 'sed', 'sort', 'tail', 'tar', 'uname',
)


class TestInstaller(unittest.TestCase):
    def setUp(self) -> None:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        self.sandbox = Path(temporary_directory.name)
        test_home = self.sandbox / 'home'
        self.tools = self.sandbox / 'bin'
        self.downloads = self.sandbox / 'downloads'
        for directory in (test_home, self.tools, self.downloads):
            directory.mkdir()

        data = test_home / 'data'
        config = test_home / 'config'
        self.prefix = data / APP
        self.launcher = test_home / '.local/bin' / APP
        self.desktop = data / 'applications' / f'{APP}.desktop'
        self.icon = data / 'icons/hicolor/scalable/apps' / f'{APP}.svg'
        self.preset = config / APP / 'preset.json'
        self.unit_file = config / 'systemd/user' / UNIT
        self.service_calls = self.sandbox / 'service-calls'
        self.python_setup_calls = self.sandbox / 'python-setup-calls'
        self.system_python = self.tools / 'python3'
        self.venv_python = self.prefix / 'venv/bin/python'
        self.env = {
            'HOME': str(test_home),
            'XDG_DATA_HOME': str(data),
            'XDG_CONFIG_HOME': str(config),
            'TMPDIR': str(self.downloads),
            'PATH': str(self.tools),
            'SYSTEMCTL_LOG': str(self.service_calls),
            'PYTHON_SETUP_LOG': str(self.python_setup_calls),
            'SYSTEM_DEPS_AVAILABLE': '0',
        }
        for name in SYSTEM_TOOLS:
            tool = shutil.which(name)
            if tool is None:
                self.skipTest(f'{name} is required to test the installer')
            (self.tools / name).symlink_to(tool)

        self._stub('id', 'echo 1000')
        self._stub('pipewire', 'echo "libpipewire 1.0.0"')
        self._stub('wireplumber', 'echo "libwireplumber 0.5.0"')
        for name in ('pw-cli', 'pw-dump', 'pw-record', 'pw-link'):
            self._stub(name, 'exit 0')
        self._stub('systemctl', 'printf "%s\\n" "$*" >> "$SYSTEMCTL_LOG"')
        self._stub('python3', '''case "$1:$2" in
    '-c:import sys;'*) exit 0 ;;
    '-c:import platform;'*) echo 3.9.0 ;;
    '-c:import PySide6.QtWidgets, numpy')
        if [ "${0##*/}" = python3 ]; then
            [ "$SYSTEM_DEPS_AVAILABLE" = 1 ]
        else
            [ -f "$0.deps" ]
        fi
        ;;
    '-m:venv')
        printf 'venv %s\\n' "$3" >> "$PYTHON_SETUP_LOG"
        mkdir -p "$3/bin" && cp "$0" "$3/bin/python"
        ;;
    '-m:pip')
        shift 2
        printf '%s: %s\\n' "$0" "$*" >> "$PYTHON_SETUP_LOG"
        case "$*" in
            *'PySide6-Essentials>=6.5 numpy') : > "$0.deps" ;;
        esac
        ;;
    '-m:tofu_eq')
        shift 2
        printf '%s\\n' "$0" "$PYTHONPATH" "$@"
        ;;
    *) exit 99 ;;
esac''')

    def _stub(self, name: str, body: str) -> None:
        path = self.tools / name
        path.write_text(f'#!/bin/sh\n{body}\n', encoding='utf-8')
        path.chmod(0o755)

    def _run(self, *command: str, script: Optional[str] = None) -> str:
        result = subprocess.run(
            command,
            input=script if script is not None else '',
            cwd=self.sandbox,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def _assert_installed(self) -> None:
        module = Path('tofu_eq/__main__.py')
        self.assertEqual((self.prefix / 'app' / module).read_bytes(),
                         (ROOT / module).read_bytes())
        saved_installer = self.prefix / INSTALLER.name
        self.assertEqual(saved_installer.read_bytes(), INSTALLER.read_bytes())
        self.assertTrue(os.access(saved_installer, os.X_OK))
        self.assertIn(f'Exec={self.launcher}',
                      self.desktop.read_text(encoding='utf-8').splitlines())
        self.assertEqual(self.icon.read_bytes(),
                         (ROOT / 'data' / self.icon.name).read_bytes())

    def _remove_installed_app(self, option: str) -> None:
        self._run('bash', str(INSTALLER), '--no-deps')
        for path in (self.preset, self.unit_file):
            path.parent.mkdir(parents=True)
            path.write_text('fixture', encoding='utf-8')

        self._run(str(self.prefix / INSTALLER.name), option)

        for path in (self.prefix, self.launcher, self.desktop, self.icon, self.unit_file):
            self.assertFalse(path.exists(), path)
        self.assertEqual(
            self.service_calls.read_text(encoding='utf-8').splitlines(),
            [f'--user disable --now {UNIT}', '--user daemon-reload'],
        )

    def test_no_deps_installs_files_and_launcher_forwards_arguments(self) -> None:
        output = self._run('bash', str(INSTALLER), '--no-deps')

        self.assertIn('skipped (--no-deps)', output)
        self.assertFalse((self.prefix / 'venv').exists())
        self._assert_installed()

        self.env['PYTHONPATH'] = str(self.sandbox / 'extra')
        output = self._run(str(self.launcher), '--example', 'two words')
        self.assertEqual(output.splitlines(), [
            str(self.system_python),
            f"{self.prefix / 'app'}:{self.env['PYTHONPATH']}",
            '--example',
            'two words',
        ])

    def test_venv_installs_dependencies_and_uses_private_python(self) -> None:
        self.env['SYSTEM_DEPS_AVAILABLE'] = '1'

        self._run('bash', str(INSTALLER), '--venv')

        calls = self.python_setup_calls.read_text(encoding='utf-8').splitlines()
        self.assertEqual(calls, [
            f'venv {self.prefix / "venv"}',
            f'{self.venv_python}: install --quiet --upgrade pip',
            f'{self.venv_python}: install --quiet PySide6-Essentials>=6.5 numpy',
        ])
        self.assertEqual(self._run(str(self.launcher)).splitlines()[0],
                         str(self.venv_python))

    def test_auto_uses_system_python_when_dependencies_are_available(self) -> None:
        self.env['SYSTEM_DEPS_AVAILABLE'] = '1'

        self._run('bash', str(INSTALLER))

        self.assertFalse(self.python_setup_calls.exists())
        self.assertEqual(self._run(str(self.launcher)).splitlines()[0],
                         str(self.system_python))

    def test_auto_reuses_existing_venv_when_system_dependencies_are_missing(self) -> None:
        self.venv_python.parent.mkdir(parents=True)
        shutil.copy2(self.system_python, self.venv_python)
        self.venv_python.with_suffix('.deps').touch()

        self._run('bash', str(INSTALLER))

        self.assertFalse(self.python_setup_calls.exists())
        self.assertEqual(self._run(str(self.launcher)).splitlines()[0],
                         str(self.venv_python))

    def test_stdin_install_downloads_archive_and_cleans_up(self) -> None:
        archive_path = self.sandbox / 'source.tar.gz'
        with tarfile.open(archive_path, 'w:gz') as archive:
            for relative_path in (INSTALLER.name, 'tofu_eq',
                                  f'data/{APP}.desktop', f'data/{APP}.svg'):
                archive.add(ROOT / relative_path, arcname=f'checkout/{relative_path}')
        self.env['SOURCE_ARCHIVE'] = str(archive_path)
        self._stub('curl', 'cp "$SOURCE_ARCHIVE" "$4"')

        self._run('bash', '-s', '--', '--no-deps',
                  script=INSTALLER.read_text(encoding='utf-8'))

        self._assert_installed()
        self.assertEqual([*self.downloads.iterdir()], [])

    def test_uninstall_removes_app_and_preserves_presets(self) -> None:
        self._remove_installed_app('--uninstall')

        self.assertEqual(self.preset.read_text(encoding='utf-8'), 'fixture')

    def test_purge_removes_app_and_presets(self) -> None:
        self._remove_installed_app('--purge')

        self.assertFalse(self.preset.parent.exists())
