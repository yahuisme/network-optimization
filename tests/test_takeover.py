"""Transaction fault injection; all paths temporary and sysctl always mocked."""
import unittest
import test_file_max


class TakeoverTests(unittest.TestCase):
    run_shell = test_file_max.FileMaxTests.run_shell
    def test_exact_keys_aliases_permissions_and_all_directories(self):
        self.run_shell(r'''
mkdir -p "${SYSCTL_DIRS[@]}"
printf '# fs.file-max=1\n;vm.swappiness=4\n -fs/file-max = 42 # old\nvm.swappiness=99\nvm.swappiness_extra=4\nnet.ipv4.tcp_congestion_control=cubic\n' > "$SYSCTL_MAIN"
cp "$SYSCTL_MAIN" expected
chmod 640 "$SYSCTL_MAIN"
ln -s "$SYSCTL_MAIN" "$PWD/etc/99-sysctl.conf"
ln -s "$SYSCTL_MAIN" "$PWD/run/other.conf"
printf 'fs.file-max=1\n' > "$PWD/etc/masked.conf"
printf 'fs.file-max=2\n' > "$PWD/usr/masked.conf"
printf 'vm/swappiness=30\n' > "$PWD/local/local.conf"
printf 'vm.swappiness=40\n' > "$PWD/lib/lib.conf"
printf 'vm.swappiness=50\nnet.ipv4.ip_forward=1\n' > "$PWD/etc/99-bbr.conf"
printf 'old\n' > "$PWD/owned"
ln -s "$PWD/owned" "$CONF_FILE"
chmod 600 "$PWD/owned"
if configure_network; then :; else exit 80; fi
[[ -L "$CONF_FILE" && -L "$PWD/etc/99-sysctl.conf" ]]
[[ $(stat -c %a "$SYSCTL_MAIN") = 640 && $(stat -c %a "$PWD/owned") = 600 ]]
[[ $(grep -c '^# network-optimization disabled:' "$SYSCTL_MAIN") = 2 ]]
grep -Fx 'vm.swappiness_extra=4' "$SYSCTL_MAIN"
grep -Fx 'net.ipv4.tcp_congestion_control=cubic' "$SYSCTL_MAIN"
grep -Fx ';vm.swappiness=4' "$SYSCTL_MAIN"
grep -Fx 'net.ipv4.ip_forward=1' "$PWD/etc/99-bbr.conf"
grep -Fx '# network-optimization disabled: fs.file-max=2' "$PWD/usr/masked.conf"
backups=("$SYSCTL_MAIN".network-backup.*)
[[ ${#backups[@]} = 1 ]]
cmp expected "${backups[0]}"
for file in "$PWD/etc/masked.conf" "$PWD/usr/masked.conf" "$PWD/local/local.conf" "$PWD/lib/lib.conf"; do
    grep -q '^# network-optimization disabled:' "$file"
done
''')

    def test_readonly_unrelated_directory_needs_no_write_access(self):
        self.run_shell(r'''
mkdir "$PWD/usr"
printf 'net.ipv4.ip_forward=1\n' > "$PWD/usr/vendor.conf"
cp "$PWD/usr/vendor.conf" expected
# Model a read-only vendor mount without remounting or changing host permissions.
mktemp() {
    if [[ "$1" = "$PWD/usr/"* ]]; then return 1; fi
    command mktemp "$@"
}
configure_network
cmp expected "$PWD/usr/vendor.conf"
''')

    def test_unchanged_rerun_keeps_single_external_backup(self):
        self.run_shell(r'''
mkdir "$PWD/etc"
printf 'vm.swappiness=10\nkeep.this=1\n' > "$PWD/etc/duplicate.conf"
configure_network
cp "$PWD/etc/duplicate.conf" expected
configure_network
cmp expected "$PWD/etc/duplicate.conf"
backups=("$PWD/etc/duplicate.conf".network-backup.*)
[[ ${#backups[@]} = 1 ]]
[[ $(grep -c '^vm.swappiness' "$CONF_FILE") = 1 ]]
''')

    def test_no_conflict_is_byte_identical(self):
        self.run_shell(r'''
mkdir "$PWD/etc"
printf '# comment\nvm.swappiness_extra=4' > "$PWD/etc/unrelated.conf"
cp "$PWD/etc/unrelated.conf" expected
before=$(stat -c '%i:%Y:%a' "$PWD/etc/unrelated.conf")
configure_network
cmp expected "$PWD/etc/unrelated.conf"
[[ "$before" = "$(stat -c '%i:%Y:%a' "$PWD/etc/unrelated.conf")" ]]
[[ -z $(compgen -G "$PWD/etc/*.network-backup.*") ]]
''')

    def test_wildcards_remain_byte_identical_without_blocking_takeover(self):
        self.run_shell(r'''
mkdir "$PWD/etc"
printf 'vm.*=1\nnet.ipv4.conf.*.rp_filter=1\nvm.swappines?=2\nvm.swappines[s]=3' > "$PWD/etc/z.conf"
cp "$PWD/etc/z.conf" wildcards.expected
printf 'vm.swappiness=99\n' > "$PWD/etc/a.conf"
command cat wildcards.expected >> "$PWD/etc/a.conf"
cp "$PWD/etc/a.conf" original.expected
printf '# network-optimization disabled: vm.swappiness=99\n' > expected
command cat wildcards.expected >> expected
configure_network
cmp expected "$PWD/etc/a.conf"
cmp wildcards.expected "$PWD/etc/z.conf"
backups=("$PWD/etc/a.conf".network-backup.*)
[[ ${#backups[@]} = 1 ]]
cmp original.expected "${backups[0]}"
[[ -z $(compgen -G "$PWD/etc/z.conf.network-backup.*") ]]
[[ -e "$CONF_FILE" && -e loaded ]]
''')

    def test_masked_or_missing_config_directory_fails_before_mutation(self):
        for prepare in (
            'ln -s /dev/null "$CONF_FILE"',
            'CONF_FILE="$PWD/missing/network.conf"',
        ):
            with self.subTest(prepare=prepare):
                self.run_shell(prepare + r'''
if configure_network; then exit 80; fi
[[ ! -e loaded && $(cat vm.swappiness) = 60 ]]
''')

    def test_crlf_and_unterminated_unrelated_bytes_survive(self):
        self.run_shell(r'''
mkdir "$PWD/etc"
printf 'vm.swappiness=99\r\n# comment\r\nkeep.this=1' > "$PWD/etc/crlf.conf"
printf '# network-optimization disabled: vm.swappiness=99\r\n# comment\r\nkeep.this=1' > expected
configure_network
cmp expected "$PWD/etc/crlf.conf"
''')

    def test_equal_values_and_unterminated_last_line(self):
        self.run_shell(r'''
mkdir "$PWD/etc"
printf 'vm.swappiness=10\nfs.file-max=262144\nkeep.this=1' > "$PWD/etc/equal.conf"
configure_network
printf '# network-optimization disabled: vm.swappiness=10\n# network-optimization disabled: fs.file-max=262144\nkeep.this=1' > expected
cmp expected "$PWD/etc/equal.conf"
''')

    def test_generation_and_snapshot_fail_before_edits(self):
        for fault in [
            'apply_optimizations() { printf partial > "$CONF_WRITE_FILE"; return 1; }',
            'sysctl() { return 1; }',
            'cat() { return 1; }',
        ]:
            with self.subTest(fault=fault):
                self.run_shell(r'''
mkdir "$PWD/etc"
printf 'vm.swappiness=10\n' > "$PWD/etc/a.conf"
cp "$PWD/etc/a.conf" expected
''' + fault + r'''
if configure_network; then exit 80; fi
cmp expected "$PWD/etc/a.conf"
[[ ! -e "$CONF_FILE" && ! -e loaded ]]
''')

    def test_multifile_rollback_faults(self):
        faults = [
            'LOADER_RC=7',
            'OTHER_OVERRIDE=11',
            '''cat() { if [[ "$*" = *b.conf.network-stage* ]]; then printf partial; return 1; fi; command cat "$@"; }''',
            '''cp() { if [[ "$*" = *b.conf.network-backup* ]]; then return 1; fi; command cp "$@"; }''',
            '''mv() { return 1; }''',
            '''config_targets() { printf 'fs.file-max=123\\n'; return 1; }''',
            '''awk() { if [[ "$*" = *canonical* ]]; then printf partial; return 1; fi; command awk "$@"; }''',
        ]
        for fault in faults:
            with self.subTest(fault=fault):
                self.run_shell(r'''
mkdir "$PWD/etc" "$PWD/usr"
printf 'vm.swappiness=99\nkeep.this=3\n' > "$PWD/etc/a.conf"
printf 'fs.file-max=1\n' > "$PWD/etc/b.conf"
printf 'vm.swappiness=77\nvm.*=1\n' > "$PWD/usr/a.conf"
cp "$PWD/etc/a.conf" a.expected
cp "$PWD/etc/b.conf" b.expected
cp "$PWD/usr/a.conf" shadowed.expected
''' + fault + r'''
if configure_network; then exit 80; fi
cmp a.expected "$PWD/etc/a.conf"
cmp b.expected "$PWD/etc/b.conf"
cmp shadowed.expected "$PWD/usr/a.conf"
[[ ! -e "$CONF_FILE" ]]
[[ $(command cat fs.file-max) = 262144 && $(command cat vm.swappiness) = 60 ]]
''')

    def test_recovery_failures_attempt_other_components(self):
        self.run_shell(r'''
mkdir "$PWD/etc"
printf 'original\n' > "$CONF_FILE"
printf 'vm.swappiness=99\n' > "$PWD/etc/a.conf"
printf 'fs.file-max=1\n' > "$PWD/etc/b.conf"
cp "$PWD/etc/b.conf" expected
LOADER_RC=7
cp() {
    if [[ -e loaded && ( "$*" = *.previous.* || "$*" = *a.conf.network-backup.* ) ]]; then return 1; fi
    command cp "$@"
}
# Preserve the real mock and fail one runtime recovery write only.
eval "$(declare -f sysctl | sed '1s/sysctl/mock_sysctl/')"
sysctl() { if [[ "$1" = -w && "$2" = vm.swappiness=* ]]; then return 1; fi; mock_sysctl "$@"; }
if configure_network; then exit 80; fi
cmp expected "$PWD/etc/b.conf"
[[ -n $(compgen -G "$CONF_FILE.previous.*") ]]
[[ -n $(compgen -G "$PWD/etc/a.conf.network-backup.*") ]]
[[ -n $(compgen -G "$CONF_FILE.runtime.*") ]]
''')
