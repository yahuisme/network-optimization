"""Real Swap functions against temporary files and mocked kernel commands."""
import pathlib
import re
import subprocess
import tempfile
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[1] / 'script.sh').read_text()


def functions():
    names = ['configure_swap', 'ensure_swap_fstab_entry', 'append_swap_fstab_entry']
    blocks = []
    for name in names:
        match = re.search(r'^' + name + r'\(\) \{\n.*?^\}', SOURCE, re.M | re.S)
        assert match is not None, name
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
    if [[ "$1" = --show=NAME,PRIO ]]; then
        while IFS= read -r name; do printf '%s 0\n' "$name"; done < active
        return
    fi
    while [[ "$1" = -p || "$1" = -o ]]; do shift 2; done
    case "$1" in
        --show=NAME,SIZE)
            while IFS= read -r name; do printf '%s %s\n' "$name" "${SIZE_BYTES:-1073737728}"; done < active ;;
        --show=NAME) cat active ;;
        *) printf '%s\n' "$1" >> active ;;
    esac
}
swapoff() { grep -Fxv "$1" active > active.new || :; mv active.new active; }
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

    def test_matching_fstab_real_short_write_preserves_bytes_and_mode(self):
        self.run_shell(r'''
printf 'swap\n' > "$SWAP_FILE"
printf '%s\n' "$SWAP_FILE" > active
printf '#%0999d\n' 0 > fstab
chmod 640 fstab
cp -p fstab expected
(
    trap '' XFSZ
    ulimit -f 1
    if configure_swap; then exit 80; else exit 0; fi
)
cmp fstab expected
[[ $(stat -c %a fstab) = 640 && $(cat active) = "$SWAP_FILE" ]]
! compgen -G "$PWD/fstab.network.*"
''')

    def test_partial_swapoff_restores_actual_priority_and_fstab_discard(self):
        self.run_shell(r'''
printf '/dev/mock1\n/dev/mock2\n' > active
printf '/dev/mock1 100\n/dev/mock2 200\n' > priorities
SIZE_BYTES=268431360
printf '/dev/mock1 none swap pri=7,discard=pages,noauto 0 0\n/dev/inactive none swap pri=88 0 0\n' > fstab
cp fstab expected
swapon() {
    case "$1" in
        --show=NAME,SIZE) while read -r name; do printf '%s %s\n' "$name" "$SIZE_BYTES"; done < active ;;
        --show=NAME,PRIO) awk 'NR==FNR {p[$1]=$2; next} {print $0, p[$0]}' priorities active ;;
        --show=NAME) cat active ;;
        *)
            [[ "$*" != *-a* && "$*" != *--all* ]] || return 99
            local name=${@: -1} options='' priority=-1
            while (( $# > 1 )); do
                case "$1" in -p) priority=$2; shift 2 ;; -o) options=$2; shift 2 ;; *) return 98 ;; esac
            done
            printf '%s %s %s\n' "$name" "$priority" "$options" >> recovered
            printf '%s\n' "$name" >> active ;;
    esac
}
swapoff() {
    [[ "$1" != /dev/mock2 ]] || return 4
    grep -Fxv "$1" active > active.new || :
    command mv active.new active
}
if configure_swap; then exit 80; fi
cmp fstab expected
[[ $(sort active) = $'/dev/mock1\n/dev/mock2' ]]
grep -Fx '/dev/mock1 100 discard=pages' recovered
[[ $(wc -l < recovered) = 1 ]]
''')

    def test_automatic_negative_priorities_survive_partial_swapoff(self):
        self.run_shell(r'''
printf '/dev/mock1\n/dev/mock2\n/dev/mock3\n' > active
printf '/dev/mock1 -2\n/dev/mock2 -3\n/dev/mock3 -4\n' > priorities
cp priorities priorities.expected
SIZE_BYTES=134213632
swapon() {
    case "$1" in
        --show=NAME,SIZE) while read -r name; do printf '%s %s\n' "$name" "$SIZE_BYTES"; done < active ;;
        --show=NAME,PRIO) cat priorities ;;
        --show=NAME) cat active ;;
        *)
            local name=${@: -1} priority=-1
            while (( $# > 1 )); do
                case "$1" in
                    -p) [[ "$2" -ge 0 ]] || return 97; priority=$2; shift 2 ;;
                    -o) shift 2 ;;
                    *) return 98 ;;
                esac
            done
            # Linux assigns automatic negatives below the least active priority.
            if (( priority < 0 )); then
                priority=$(awk 'BEGIN { p=-1 } $2 < p { p=$2 } END { print p-1 }' priorities)
            fi
            printf '%s %s\n' "$name" "$priority" >> priorities
            printf '%s\n' "$name" >> active ;;
    esac
}
swapoff() {
    [[ "$1" != /dev/mock2 ]] || return 4
    local priority
    priority=$(awk -v name="$1" '$1 == name { print $2 }' priorities)
    # Linux compacts lower automatic priorities after removing a negative one.
    awk -v name="$1" -v p="$priority" '$1 != name { if (p < 0 && $2 < p) $2++; print }' priorities > priorities.new
    command mv priorities.new priorities
    grep -Fxv "$1" active > active.new || :
    command mv active.new active
}
if configure_swap; then exit 80; fi
[[ $(sort priorities) = "$(sort priorities.expected)" ]]
[[ $(sort active) = $'/dev/mock1\n/dev/mock2\n/dev/mock3' ]]
''')

    def test_rollback_priority_mismatch_retains_recovery_evidence(self):
        self.run_shell(r'''
printf '/dev/mock1\n/dev/mock2\n' > active
SIZE_BYTES=268431360
swapon() {
    case "$1" in
        --show=NAME,SIZE) while read -r name; do printf '%s %s\n' "$name" "$SIZE_BYTES"; done < active ;;
        --show=NAME,PRIO)
            while read -r name; do
                if [[ "$name" = /dev/mock2 ]]; then printf '%s 200\n' "$name"
                elif [[ -e recovered ]]; then printf '%s -2\n' "$name"
                else printf '%s 100\n' "$name"; fi
            done < active ;;
        --show=NAME) cat active ;;
        *) touch recovered; printf '%s\n' "${@: -1}" >> active ;;
    esac
}
swapoff() {
    [[ "$1" != /dev/mock2 ]] || return 4
    grep -Fxv "$1" active > active.new || :
    command mv active.new active
}
if configure_swap; then exit 80; fi
[[ -e recovered && -n $(compgen -G "$PWD/fstab.network.*") ]]
''')

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

    def test_replacement_preserves_fstab_symlink_and_target_mode(self):
        self.run_shell(r'''
mkdir config
mv fstab config/boot
chmod 640 config/boot
ln -s config/boot fstab
configure_swap
[[ -L fstab && $(stat -c %a config/boot) = 640 ]]
grep -Fx "$SWAP_FILE none swap sw 0 0" config/boot
''')

    def test_replacement_does_not_write_fstab_before_active_readback(self):
        self.run_shell(r'''
printf '/dev/mock none swap sw 0 0\n' > fstab
cp fstab expected
printf '/dev/mock\n' > active
SIZE_BYTES=536866816
eval "$(declare -f swapon | sed '1s/swapon/mock_swapon/')"
swapon() {
    if [[ "$1" = --show=NAME && -e installed ]]; then
        cmp -s fstab expected || touch fstab_changed_early
        return 7
    fi
    if [[ "$1" = "$SWAP_FILE" ]]; then touch installed; fi
    mock_swapon "$@"
}
if configure_swap; then exit 80; fi
[[ -e installed && ! -e fstab_changed_early ]]
cmp fstab expected
''')

    def test_raw_swap_path_and_fstab_discard_survive_rollback(self):
        self.run_shell(r'''
path="$PWD/old swap\\file"
raw="$PWD/old\x20swap\x5cfile"
printf '%s\n' "$raw" > active
printf '%s none swap discard=pages 0 0\n' "$PWD/old\040swap\134file" > fstab
SIZE_BYTES=536866816
eval "$(declare -f swapon | sed '1s/swapon/mock_swapon/')"
swapon() {
    case "$1" in
        --show=*) mock_swapon "$@" ;;
        "$SWAP_FILE") touch activation_attempted; return 1 ;;
        *) [[ "$#" = 5 && "$1" = -p && "$2" = 0 && "$3" = -o && "$4" = discard=pages && "$5" = "$path" ]] || return 97
           printf '%s\n' "$raw" >> active; touch restored ;;
    esac
}
swapoff() { [[ "$1" = "$path" ]] || return 98; : > active; }
if configure_swap; then exit 80; fi
[[ -e activation_attempted && -e restored && $(cat active) = "$raw" ]]
''')

    def test_swapoff_error_reconciles_snapshot_after_two_failed_queries(self):
        for outcome, failures in (('removed', 2), ('remains', 2), ('removed', 4)):
            with self.subTest(outcome=outcome, failures=failures):
                self.run_shell(f'OUTCOME={outcome}\nFAILURES={failures}\n' + r'''
printf '/dev/first\n/dev/second\n' > active
cp -p fstab expected
SIZE_BYTES=268431360
eval "$(declare -f swapon | sed '1s/swapon/mock_swapon/')"
swapon() {
    if [[ "$1" = --show=* && -s failed-queries-left ]]; then
        local left
        read -r left < failed-queries-left
        if (( left > 0 )); then
            printf '%s\n' "$((left - 1))" > failed-queries-left
            return 7
        fi
    fi
    if [[ "$1" != --show=* ]]; then
        printf '%s\n' "${@: -1}" >> restored
        if grep -Fxq -- "${@: -1}" active; then touch duplicate_activation; return 8; fi
    fi
    mock_swapon "$@"
}
swapoff() {
    if [[ "$1" = /dev/second ]]; then
        printf '%s\n' "$FAILURES" > failed-queries-left
        if [[ "$OUTCOME" = removed ]]; then : > active; fi
        return 5
    fi
    printf '/dev/second\n' > active
}
if configure_swap; then exit 80; else [[ $? = 1 ]]; fi
cmp fstab expected
if (( FAILURES > 3 )); then
    [[ $(< failed-queries-left) = 1 && ! -e restored ]]
    backup=$(compgen -G "$PWD/fstab.network.*")
    cmp "$backup" expected
    exit 0
fi
[[ $(< failed-queries-left) = 0 && ! -e duplicate_activation ]]
if [[ "$OUTCOME" = removed ]]; then
    [[ $(< restored) = $'/dev/second\n/dev/first' ]]
else
    [[ $(< restored) = /dev/first ]]
fi
[[ $(sort active) = $'/dev/first\n/dev/second' ]]
[[ -z $(compgen -G "$PWD/fstab.network.*") ]]
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
    if [[ "$1" = --show=NAME,PRIO ]]; then
        while IFS= read -r name; do printf '%s 0\n' "$name"; done < active
        return
    fi
    while [[ "$1" = -p || "$1" = -o ]]; do shift 2; done
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
    if [[ "$1" = --show=NAME,PRIO ]]; then
        while IFS= read -r name; do printf '%s 0\n' "$name"; done < active
        return
    fi
    while [[ "$1" = -p || "$1" = -o ]]; do shift 2; done
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
    if [[ "$1" = --show=NAME,PRIO ]]; then
        while IFS= read -r name; do printf '%s 0\n' "$name"; done < active
        return
    fi
    while [[ "$1" = -p || "$1" = -o ]]; do shift 2; done
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
