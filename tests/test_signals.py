"""Real catchable signals after mocked external mutations; never host writes."""
import pathlib
import subprocess
import tempfile
import unittest

import test_file_max
import test_swap


class SignalTests(unittest.TestCase):
    def run_fixture(self, functions, setup, body, scripts, expected=0, verify=''):
        with tempfile.TemporaryDirectory(prefix='network-signal-') as temp:
            root = pathlib.Path(temp)
            for name, content in scripts.items():
                target = root / name
                target.write_text('#!/usr/bin/env bash\nset -eu\n' + content)
                target.chmod(0o700)
            fixture = root / 'fixture.sh'
            fixture.write_text(functions + '\n' + setup + '\n' + body)
            result = subprocess.run(['bash', str(fixture)], cwd=temp, text=True,
                                    capture_output=True, timeout=15)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            if verify:
                checked = subprocess.run(['bash', '-Eeuo', 'pipefail', '-c', verify],
                                         cwd=temp, text=True, capture_output=True, timeout=5)
                self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_swap_signal_after_completed_command_restores_old_state(self):
        for signal, code in (('TERM', 143), ('INT', 130)):
            for boundary in ('swapoff', 'old-mv', 'new-mv', 'fstab-mv'):
                with self.subTest(signal=signal, boundary=boundary):
                    self.run_fixture(test_swap.functions(), test_swap.SETUP,
                                     f'SIGNAL={signal}\nBOUNDARY={boundary}\n' + r'''
export SIGNAL BOUNDARY
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
cp -p fstab expected
swapoff() { "$PWD/mock-swapoff" "$@"; }
mv() { "$PWD/mock-mv" "$@"; }
trap 'printf term >> prior-fired' TERM
trap 'printf int >> prior-fired' INT
before=$(trap -p INT TERM)
if configure_swap; then exit 80; else rc=$?; fi
printf 'returned=%s\n' "$rc"
''' + f'[[ $rc = {code} ]]\n' + r'''
[[ $(cat "$SWAP_FILE") = 'old swap' && $(cat active) = "$SWAP_FILE" ]]
cmp expected fstab
[[ $(trap -p INT TERM) = "$before" && ! -e prior-fired ]]
kill -s "$SIGNAL" "$BASHPID"
[[ -s prior-fired ]]
! compgen -G "$SWAP_FILE.new.*"
! compgen -G "$SWAP_FILE.old.*"
! compgen -G "$PWD/fstab.network.*"
''', {
                        'mock-swapoff': r'''
grep -Fxv "$1" active > active.new || :
/usr/bin/mv active.new active
if [[ "$BOUNDARY" = swapoff && ! -e sent ]]; then
    touch sent
    kill -s "$SIGNAL" "$PPID"
fi
''',
                        'mock-mv': r'''
/usr/bin/mv "$@"
if [[ ! -e sent && ( ( "$BOUNDARY" = new-mv && "$*" = *swapfile.new.* ) || ( "$BOUNDARY" = old-mv && "$*" = *swapfile.old.* ) || ( "$BOUNDARY" = fstab-mv && "$*" = *fstab.network-stage.* ) ) ]]; then
    touch sent
    kill -s "$SIGNAL" "$PPID"
fi
''',
                    })

    def test_signal_and_nonzero_command_after_swap_mutation_still_recovers(self):
        for boundary in ('swapoff', 'old-mv', 'new-mv', 'fstab-mv'):
            with self.subTest(boundary=boundary):
                self.run_fixture(test_swap.functions(), test_swap.SETUP,
                                 f'BOUNDARY={boundary}\n' + r'''
export BOUNDARY
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
cp fstab expected
swapoff() { "$PWD/mock-swapoff" "$@"; }
mv() { "$PWD/mock-mv" "$@"; }
if configure_swap; then exit 80; else [[ $? = 143 ]]; fi
[[ $(cat "$SWAP_FILE") = 'old swap' && $(cat active) = "$SWAP_FILE" ]]
cmp expected fstab
! compgen -G "$SWAP_FILE.old.*"
! compgen -G "$SWAP_FILE.new.*"
''', {
                    'mock-swapoff': r'''
grep -Fxv "$1" active > active.new || :
/usr/bin/mv active.new active
if [[ "$BOUNDARY" = swapoff && ! -e sent ]]; then
    touch sent; kill -TERM "$PPID"; exit 143
fi
''',
                    'mock-mv': r'''
/usr/bin/mv "$@"
if [[ ! -e sent && ( ( "$BOUNDARY" = old-mv && "$*" = *swapfile.old.* ) || ( "$BOUNDARY" = new-mv && "$*" = *swapfile.new.* ) || ( "$BOUNDARY" = fstab-mv && "$*" = *fstab.network-stage.* ) ) ]]; then
    touch sent; kill -TERM "$PPID"; exit 143
fi
''',
                })

    def test_direct_errexit_call_restores_before_signal_status_exit(self):
        for signal, code in (('TERM', 143), ('INT', 130)):
            with self.subTest(signal=signal):
                self.run_fixture(test_swap.functions(), test_swap.SETUP,
                                 f'SIGNAL={signal}\n' + r'''
export SIGNAL
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
cp fstab expected
swapoff() { "$PWD/mock-swapoff" "$@"; }
configure_swap
: > should-not-reach
''', {'mock-swapoff': r'''
grep -Fxv "$1" active > active.new || :
/usr/bin/mv active.new active
if [[ ! -e sent ]]; then touch sent; kill -s "$SIGNAL" "$PPID"; fi
'''}, expected=code, verify=r'''
[[ $(cat swapfile) = 'old swap' && $(cat active) = "$PWD/swapfile" && ! -e should-not-reach ]]
cmp expected fstab
''')
                self.run_fixture(test_file_max.FUNCTIONS, test_file_max.SETUP,
                                 f'SIGNAL={signal}\n' + r'''
export SIGNAL
printf 'original\n' > "$CONF_FILE"
eval "$(declare -f sysctl | sed '1s/sysctl/mock_sysctl/')"
sysctl() { if [[ "$1" = -p ]]; then "$PWD/mock-load"; else mock_sysctl "$@"; fi; }
configure_network
: > should-not-reach
''', {'mock-load': 'printf "10\\n" > vm.swappiness\nkill -s "$SIGNAL" "$PPID"\n'},
                                 expected=code, verify=r'''
[[ $(cat network.conf) = original && $(cat vm.swappiness) = 60 && ! -e should-not-reach ]]
''')

    def test_success_and_ordinary_failure_restore_prior_signal_traps(self):
        for fault in ('', 'mkswap() { return 8; }', 'swapoff() { return 4; }'):
            with self.subTest(swap_fault=fault):
                self.run_fixture(test_swap.functions(), test_swap.SETUP, fault + r'''
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
trap 'printf int >> prior-fired' INT
trap 'printf term >> prior-fired' TERM
before=$(trap -p INT TERM)
if configure_swap; then :; else [[ $? = 1 ]]; fi
[[ $(trap -p INT TERM) = "$before" ]]
''', {})
        for fault in ('', 'LOADER_RC=7'):
            with self.subTest(network_fault=fault):
                self.run_fixture(test_file_max.FUNCTIONS, test_file_max.SETUP, fault + r'''
trap 'printf int >> prior-fired' INT
trap 'printf term >> prior-fired' TERM
before=$(trap -p INT TERM)
if configure_network; then :; else [[ $? = 7 ]]; fi
[[ $(trap -p INT TERM) = "$before" ]]
''', {})

    def test_network_signal_during_post_commit_cleanup_preserves_takeover_backup(self):
        self.run_fixture(test_file_max.FUNCTIONS, test_file_max.SETUP, r'''
mkdir etc
printf 'vm.swappiness=99\n' > etc/other.conf
cp -p etc/other.conf other.expected
rm() { "$PWD/mock-rm" "$@"; }
trap 'touch prior_fired' TERM
if configure_network; then rc=0; else rc=$?; fi
[[ -e sent && -e prior_fired && "$rc" = 0 ]]
[[ $(cat vm.swappiness) = 10 ]]
grep -Fx '# network-optimization disabled: vm.swappiness=99' etc/other.conf
backups=(etc/other.conf.network-backup.*)
[[ ${#backups[@]} = 1 ]]
cmp other.expected "${backups[0]}"
''', {'mock-rm': r'''
/usr/bin/rm "$@"
if [[ ! -e sent && "$*" = *.runtime.* ]]; then
    touch sent; kill -TERM "$PPID"
fi
'''})

    def test_network_signal_during_partial_load_restores_files_and_runtime(self):
        for signal, code in (('TERM', 143), ('INT', 130)):
            for restore in (False, True):
                with self.subTest(signal=signal, restore=restore):
                    self.run_fixture(test_file_max.FUNCTIONS, test_file_max.SETUP,
                                     f'SIGNAL={signal}\n' + r'''
export SIGNAL
mkdir etc
printf 'original\n' > "$CONF_FILE"
printf 'vm.swappiness=99\n' > etc/other.conf
cp -p etc/other.conf other.expected
printf 'vm.swappiness=30\n' > backup
# Keep snapshot/readback mock; make only the loader an external mutator.
eval "$(declare -f sysctl | sed '1s/sysctl/mock_sysctl/')"
sysctl() {
    if [[ "$1" = -p ]]; then "$PWD/mock-load"; else mock_sysctl "$@"; fi
}
trap 'printf term >> prior-fired' TERM
trap 'printf int >> prior-fired' INT
before=$(trap -p INT TERM)
''' + ('if configure_network "$PWD/backup";' if restore else 'if configure_network;') + r''' then exit 80; else rc=$?; fi
printf 'returned=%s\n' "$rc"
''' + f'[[ $rc = {code} ]]\n' + r'''
[[ $(cat "$CONF_FILE") = original && $(cat vm.swappiness) = 60 && $(cat fs.file-max) = 262144 ]]
cmp other.expected etc/other.conf
[[ $(trap -p INT TERM) = "$before" && ! -e prior-fired ]]
kill -s "$SIGNAL" "$BASHPID"
[[ -s prior-fired ]]
! compgen -G "$CONF_FILE.runtime.*"
! compgen -G "$CONF_FILE.tmp.*"
! compgen -G "$CONF_FILE.previous.*"
''', {'mock-load': r'''
printf '10\n' > vm.swappiness
touch loaded
kill -s "$SIGNAL" "$PPID"
'''})


if __name__ == '__main__':
    unittest.main()
