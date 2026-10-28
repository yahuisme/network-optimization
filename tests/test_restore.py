"""Restore exercises the production transaction with private paths/sysctl mocks."""
import unittest
import test_file_max


class RestoreTests(unittest.TestCase):
    run_shell = test_file_max.FileMaxTests.run_shell

    def run_restore(self, body):
        return self.run_shell(test_file_max.extract('usage') + '\n' +
                              test_file_max.extract('main') + r'''
BOLD='' NC='' SCRIPT_VERSION=test
require_root() { :; }
printf 'vm.swappiness=10\n' > "$CONF_FILE"
printf 'vm.swappiness=30\n' > "$CONF_FILE.bak_test"
printf '60\n' > vm.swappiness
''' + body)

    def test_failed_load_or_readback_restores_config_and_runtime(self):
        for fault in ('LOADER_RC=7', 'OTHER_OVERRIDE=31'):
            with self.subTest(fault=fault):
                self.run_restore(fault + r'''
if (main restore); then exit 80; fi
[[ $(cat "$CONF_FILE") = vm.swappiness=10 ]]
[[ $(cat vm.swappiness) = 60 ]]
[[ $(cat "$CONF_FILE.bak_test") = vm.swappiness=30 ]]
! grep -q -- '--system' calls
''')

    def test_snapshot_failure_does_not_replace_current_config(self):
        self.run_restore(r'''
sysctl() { return 1; }
if (main restore); then exit 80; fi
[[ $(cat "$CONF_FILE") = vm.swappiness=10 ]]
''')

    def test_empty_or_failed_backup_staging_preserves_current_state(self):
        for fault in (
            ': > "$CONF_FILE.bak_test"',
            '''cp() { if [[ "$1" = -- && "$2" = *.bak_* ]]; then
                printf partial > "$3"; return 1; fi; command cp "$@"; }''',
        ):
            with self.subTest(fault=fault):
                self.run_restore(fault + r'''
if (main restore); then exit 80; fi
[[ $(cat "$CONF_FILE") = vm.swappiness=10 && $(cat vm.swappiness) = 60 ]]
[[ ! -e loaded ]]
[[ -z $(compgen -G "$CONF_FILE.tmp.*") ]]
''')

    def test_missing_config_and_symlink_config(self):
        for prepare, verify in (
            ('rm "$CONF_FILE"', '[[ ! -e "$CONF_FILE" ]]'),
            ('mv "$CONF_FILE" owned; ln -s "$PWD/owned" "$CONF_FILE"; chmod 640 owned',
             '[[ -L "$CONF_FILE" && $(cat owned) = vm.swappiness=10 && $(stat -c %a owned) = 640 ]]'),
        ):
            with self.subTest(prepare=prepare):
                self.run_restore(prepare + '\nLOADER_RC=7\n' + r'''
if (main restore); then exit 80; fi
[[ $(cat vm.swappiness) = 60 ]]
''' + verify)

    def test_failed_config_recovery_does_not_skip_runtime_recovery(self):
        self.run_restore(r'''
LOADER_RC=7
cp() { if [[ "$*" = *.previous.* && -e loaded ]]; then return 1; fi; command cp "$@"; }
if (main restore); then exit 80; fi
[[ $(cat vm.swappiness) = 60 ]]
[[ -n $(compgen -G "$CONF_FILE.previous.*") ]]
''')

    def test_failed_runtime_recovery_keeps_exact_snapshot(self):
        self.run_restore(r'''
LOADER_RC=7
eval "$(declare -f sysctl | sed '1s/sysctl/mock_sysctl/')"
sysctl() { if [[ "$1" = -w ]]; then return 1; fi; mock_sysctl "$@"; }
if (main restore); then exit 80; fi
[[ $(cat "$CONF_FILE") = vm.swappiness=10 ]]
snapshots=("$CONF_FILE".runtime.*)
[[ ${#snapshots[@]} = 1 && $(cat "${snapshots[0]}") = vm.swappiness=60 ]]
''')

    def test_restore_does_not_require_hardware_detection(self):
        self.run_restore(r'''
unset VM_TIER TOTAL_MEM CPU_CORES FILE_MAX
(main restore)
[[ $(cat vm.swappiness) = 30 ]]
''')

    def test_success_does_not_take_over_other_files_or_rotate_backup(self):
        self.run_restore(r'''
mkdir "$PWD/etc"
printf 'vm.swappiness=99\n' > "$PWD/etc/user.conf"
(main restore)
[[ $(cat vm.swappiness) = 30 ]]
[[ $(cat "$PWD/etc/user.conf") = vm.swappiness=99 ]]
backups=("$CONF_FILE".bak_*)
[[ ${#backups[@]} = 1 ]]
''')
