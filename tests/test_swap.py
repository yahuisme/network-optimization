"""Real Swap functions against temporary files and mocked kernel commands."""
import pathlib
import re
import subprocess
import tempfile
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[1] / 'script.sh').read_text()


def functions():
    names = ['configure_swap', 'ensure_swap_fstab_entry', 'valid_swap_file']
    blocks = []
    for name in names:
        match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE, re.M | re.S)
        if match:
            blocks.append(match.group(0))
    # Only absolute system paths, never a backup-relative name.
    return re.sub(r'(?<![\w$}])(/etc/fstab)', '$PWD/fstab', '\n'.join(blocks))


SETUP = r'''
set -Eeuo pipefail
TOTAL_MEM=1024
SWAP_FILE="$PWD/swapfile"
section() { :; }; step() { :; }
warning() { printf 'WARN %s\n' "$*"; }
error() { printf 'ERROR %s\n' "$*"; }
success() { printf 'SUCCESS %s\n' "$*"; }
printf '# original fstab\n' > fstab
: > active
swapon() {
    case "$1" in
        --show=NAME,SIZE)
            while IFS= read -r name; do printf '%s %s\n' "$name" "${SIZE_BYTES:-1073737728}"; done < active ;;
        --show=NAME) cat active ;;
        *) printf '%s\n' "$1" >> active ;;
    esac
}
swapoff() { grep -Fxv "$1" active > active.new || :; mv active.new active; }
blkid() { [[ ${SIGNATURE:-swap} = swap ]] && printf 'swap\n'; }
df() { printf 'Filesystem 1048576-blocks Used Available Capacity Mounted\nmock 10000 100 9900 1%% /\n'; }
fallocate() { printf 'new swap\n' > "${@: -1}"; }
dd() { return 99; }
mkswap() { return 0; }
'''


class SwapTests(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory(prefix='network-swap-') as temp:
            script = pathlib.Path(temp) / 'fixture.sh'
            script.write_text(functions() + '\n' + SETUP + '\n' + body)
            result = subprocess.run(['bash', str(script)], cwd=temp, text=True,
                                    capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_replacement_preserves_unterminated_fstab(self):
        self.run_shell(r'''
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
printf 'UUID=example / ext4 defaults 0 1' > fstab
configure_swap
grep -Fx 'UUID=example / ext4 defaults 0 1' fstab
[[ $(grep -Fxc "$SWAP_FILE none swap sw 0 0" fstab) = 1 ]]
''')

    def test_replacement_removes_old_swap_boot_entries(self):
        self.run_shell(r'''
printf '/dev/mock-partition\n' > active
SIZE_BYTES=536866816
printf '# keep\n/dev/mock-partition none swap sw 0 0\nUUID=old none swap defaults 0 0\nUUID=root / ext4 defaults 0 1\n' > fstab
configure_swap
[[ $(grep -cE '^(/dev/mock-partition|UUID=old) ' fstab) = 0 ]]
grep -Fx 'UUID=root / ext4 defaults 0 1' fstab
[[ $(grep -Fxc "$SWAP_FILE none swap sw 0 0" fstab) = 1 ]]
''')

    def test_successful_swap_replacement(self):
        self.run_shell(r'''
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
configure_swap
[[ $(cat "$SWAP_FILE") = 'new swap' && $(cat active) = "$SWAP_FILE" ]]
[[ $(grep -Fxc "$SWAP_FILE none swap sw 0 0" fstab) = 1 ]]
! compgen -G "$SWAP_FILE.old.*"
! compgen -G "$SWAP_FILE.new.*"
''')

    def test_activation_failure_restores_files_and_runtime(self):
        self.run_shell(r'''
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
cp fstab expected
swapon() {
    case "$1" in
        --show=NAME,SIZE) printf '%s %s\n' "$SWAP_FILE" "$SIZE_BYTES" ;;
        --show=NAME) cat active ;;
        *) [[ $(cat "$1") = 'old swap' ]] || return 1; printf '%s\n' "$1" >> active ;;
    esac
}
if configure_swap; then exit 80; fi
[[ $(cat "$SWAP_FILE") = 'old swap' && $(cat active) = "$SWAP_FILE" ]]
cmp fstab expected
''')

    def test_matching_entry_repairs_unterminated_fstab(self):
        self.run_shell(r'''
printf 'swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
printf 'UUID=example / ext4 defaults 0 1' > fstab
configure_swap
[[ $(grep -Fxc "$SWAP_FILE none swap sw 0 0" fstab) = 1 ]]
grep -Fx 'UUID=example / ext4 defaults 0 1' fstab
''')

    def test_dangling_swap_symlink_is_preserved(self):
        self.run_shell(r'''
ln -s "$PWD/missing-user-file" "$SWAP_FILE"
if configure_swap; then exit 80; fi
[[ -L "$SWAP_FILE" && ! -e missing-user-file ]]
[[ $(cat fstab) = '# original fstab' ]]
''')

    def test_activation_readback_failure_restores_old_swap(self):
        self.run_shell(r'''
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
cp fstab expected
swapon() {
    case "$1" in
        --show=NAME,SIZE) printf '%s %s\n' "$SWAP_FILE" "$SIZE_BYTES" ;;
        --show=NAME) cat active ;;
        *)
            # Simulate successful activation return, but no active new file.
            if [[ $(cat "$1") = 'old swap' ]]; then printf '%s\n' "$1" >> active; fi ;;
    esac
}
if configure_swap; then exit 80; fi
[[ $(cat "$SWAP_FILE") = 'old swap' && $(cat active) = "$SWAP_FILE" ]]
cmp fstab expected
''')

    def test_recovery_blocked_new_swap_still_restores_fstab_and_partition(self):
        for failure in ('query', 'swapoff'):
            with self.subTest(failure=failure):
                self.run_shell('FAILURE=' + failure + r'''
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n/dev/mock\n' "$SWAP_FILE" > active
SIZE_BYTES=268431360
cp fstab expected
swapon() {
    case "$1" in
        --show=NAME,SIZE)
            while IFS= read -r name; do printf '%s %s\n' "$name" "$SIZE_BYTES"; done < active ;;
        --show=NAME)
            if [[ -e installed ]]; then
                [[ "$FAILURE" != query ]] || return 1
                printf '%s\n/dev/unexpected\n' "$SWAP_FILE"
            else cat active; fi ;;
        *) [[ "$1" != "$SWAP_FILE" ]] || touch installed
            printf '%s\n' "$1" >> active ;;
    esac
}
swapoff() {
    if [[ -e installed && "$1" = "$SWAP_FILE" ]]; then return 1; fi
    grep -Fxv "$1" active > active.new || :; mv active.new active
}
if configure_swap; then exit 80; fi
cmp fstab expected
[[ $(cat "$SWAP_FILE") = 'new swap' ]]
[[ -n $(compgen -G "$SWAP_FILE.old.*") ]]
[[ -n $(compgen -G "$PWD/fstab.network.*") ]]
grep -Fx /dev/mock active
''')

    def test_preparation_failures_leave_old_files_and_state(self):
        for fault in (
            'mkswap() { return 1; }',
            'fallocate() { return 1; }',
            'swapoff() { return 1; }',
        ):
            with self.subTest(fault=fault):
                self.run_shell(fault + r'''
printf 'old swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
SIZE_BYTES=536866816
cp fstab expected
if configure_swap; then exit 80; fi
cmp fstab expected
[[ $(cat "$SWAP_FILE") = 'old swap' && $(cat active) = "$SWAP_FILE" ]]
[[ -z $(compgen -G "$SWAP_FILE.new.*") ]]
''')

    def test_invalid_size_fails_before_changes(self):
        self.run_shell(r'''
printf '/dev/mock\n' > active
SIZE_BYTES=invalid
cp fstab expected
if configure_swap; then exit 80; fi
cmp fstab expected
[[ ! -e "$SWAP_FILE" ]]
''')

    def test_matching_owned_swap_rejects_duplicate_boot_entries(self):
        self.run_shell(r'''
printf 'swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
printf '%s none swap sw 0 0\n%s none swap sw 0 0\n' "$SWAP_FILE" "$SWAP_FILE" > fstab
cp fstab expected
if configure_swap; then exit 80; fi
cmp fstab expected
''')

    def test_matching_owned_swap_rejects_conflicting_boot_entry(self):
        self.run_shell(r'''
printf 'swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
printf '%s none swap noauto 0 0\n' "$SWAP_FILE" > fstab
cp fstab expected
if configure_swap; then exit 80; fi
cmp fstab expected
''')

    def test_matching_owned_swap_repairs_boot_entry_once(self):
        self.run_shell(r'''
printf 'swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
configure_swap
configure_swap
[[ $(grep -Fxc "$SWAP_FILE none swap sw 0 0" fstab) = 1 ]]
''')

    def test_matching_partition_preserves_inactive_user_file_or_symlink(self):
        for prepare in (
            'printf user-data > "$SWAP_FILE"',
            'printf user-data > user-file; ln -s "$PWD/user-file" "$SWAP_FILE"',
        ):
            with self.subTest(prepare=prepare):
                self.run_shell(prepare + r'''
printf '/dev/mock\n' > active
configure_swap
[[ $(cat "$SWAP_FILE") = user-data && $(cat fstab) = '# original fstab' ]]
[[ $(cat active) = /dev/mock ]]
''')

    def test_matching_partition_does_not_add_owned_entry(self):
        self.run_shell(r'''
printf '/dev/mock\n' > active
configure_swap
[[ $(cat fstab) = '# original fstab' ]]
''')


if __name__ == '__main__':
    unittest.main()
