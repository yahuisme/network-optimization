"""Isolated real-function tests; never source or run the optimizer entry point."""
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
NAMES = (
    "calculate_parameters", "add_conf", "apply_optimizations", "config_targets",
    "normalize_value", "file_max_at_least", "apply_and_verify", "manage_backups",
    "migrate_legacy_config", "configure_network",
)
SOURCE = (ROOT / "script.sh").read_text()
def extract(name):
    match = re.search(r"^" + name + r"\(\) \{(?:[^\n]*\}|\n.*?^\})",
                      SOURCE, re.M | re.S)
    assert match is not None, name
    return match.group(0)


FUNCTIONS = "\n".join(extract(name) for name in NAMES)
SETUP = r'''
set -Eeuo pipefail
CONF_FILE="$PWD/network.conf"
CONF_WRITE_FILE="$PWD/staged.conf"
LEGACY_CONF_FILE="$PWD/legacy.conf"
TOTAL_MEM=1024 CPU_CORES=1 BBR_AVAILABLE=false
section() { :; }
step() { :; }
warning() { printf 'WARNING %s\n' "$*" >&2; }
error() { printf 'ERROR %s\n' "$*" >&2; }
success() { printf 'SUCCESS %s\n' "$*"; }
sysctl_supported() { [[ "$1" = fs.file-max || "$1" = vm.swappiness ]]; }
# All sysctl calls, including rollback writes, terminate here.
sysctl() {
    printf '%s\n' "$*" >> "$PWD/calls"
    case "$1" in
        --system)
            touch "$PWD/loaded"
            while IFS='=' read -r key value; do
                printf '%s\n' "$value" > "$PWD/$key"
            done < <(config_targets "$CONF_FILE")
            if [[ ${OVERRIDE+x} ]]; then printf '%s\n' "$OVERRIDE" > "$PWD/fs.file-max"; fi
            if [[ ${OTHER_OVERRIDE+x} ]]; then printf '%s\n' "$OTHER_OVERRIDE" > "$PWD/vm.swappiness"; fi
            return "${LOADER_RC:-0}" ;;
        -n)
            if [[ "$2" = fs.file-max && ${READ_FAIL:-} = always ]]; then return 1; fi
            if [[ "$2" = fs.file-max && ${READ_FAIL:-} = loaded && -e "$PWD/loaded" && ! -e "$PWD/restored" ]]; then return 1; fi
            if [[ -f "$PWD/$2" ]]; then cat "$PWD/$2"; else printf 'unused\n'; fi ;;
        -w)
            local key=${2%%=*} value=${2#*=}
            printf '%s\n' "$value" > "$PWD/$key"
            touch "$PWD/restored" ;;
        *) return 99 ;;
    esac
}
calculate_parameters
printf '262144\n' > "$PWD/fs.file-max"
printf '60\n' > "$PWD/vm.swappiness"
'''


class FileMaxTests(unittest.TestCase):
    def run_shell(self, body):
        with tempfile.TemporaryDirectory(prefix="network-filemax-") as tmp:
            result = subprocess.run(
                ["bash", "-c", FUNCTIONS + "\n" + SETUP + "\n" + body],
                cwd=tmp, text=True, capture_output=True, timeout=15,
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_generation_preserves_higher_runtime(self):
        self.run_shell(r'''
printf '2097152\n' > "$PWD/fs.file-max"
apply_optimizations
[[ $(config_targets "$CONF_WRITE_FILE") = $'fs.file-max=2097152\nvm.swappiness=10' ]]
''')

    def test_verification_accepts_higher_override(self):
        self.run_shell(r'''
printf 'fs.file-max = 262144\n' > "$CONF_FILE"
OVERRIDE=2097152
apply_and_verify
''')


    def test_generation_boundaries(self):
        for current, expected in [
            ("262144", "262144"), ("131072", "262144"),
            ("9223372036854775807", "9223372036854775807"),
        ]:
            with self.subTest(current=current):
                self.run_shell(f'''
printf '%s\\n' '{current}' > "$PWD/fs.file-max"
apply_optimizations
[[ $(config_targets "$CONF_WRITE_FILE") = $'fs.file-max={expected}\\nvm.swappiness=10' ]]
''')

    def test_generation_invalid_or_unreadable_preserves_configs(self):
        for value in ["", "invalid", "-1", "1.5", "1e6", "12 34", "unreadable"]:
            with self.subTest(value=value):
                self.run_shell(f'''
printf '%s\\n' '{value}' > "$PWD/fs.file-max"
[[ '{value}' != unreadable ]] || READ_FAIL=always
printf 'original\\n' > "$CONF_FILE"
printf 'legacy\\n' > "$LEGACY_CONF_FILE"
if configure_network; then exit 80; fi
[[ $(cat "$CONF_FILE") = original && $(cat "$LEGACY_CONF_FILE") = legacy ]]
[[ ! -e "$PWD/loaded" ]]
[[ -z $(compgen -G "$CONF_FILE.tmp.*") ]]
''')

    def test_verification_boundaries(self):
        cases = [
            ("262144", "262144", True), ("262144", "131072", False),
            ("262144", "9223372036854775807", True),
            ("9223372036854775807", "9223372036854775807", True),
            ("9223372036854775807", "9223372036854775806", False),
            ("9223372036854775806", "9223372036854775807", True),
            ("262144", "000262144", True),
            ("262144", "", False), ("262144", "invalid", False),
            ("262144", "-1", False), ("262144", "1e9", False),
            ("262144", "262144.0", False), ("262144", "12 34", False),
            ("invalid", "2097152", False),
        ]
        for target, actual, ok in cases:
            with self.subTest(target=target, actual=actual):
                result = self.run_shell(f'''
printf 'fs.file-max = %s\\n' '{target}' > "$CONF_FILE"
OVERRIDE='{actual}'
if apply_and_verify; then rc=0; else rc=$?; fi
[[ $rc {'-eq' if ok else '-ne'} 0 ]]
''')
                self.assertEqual("SUCCESS" in result.stdout, ok)

    def test_verification_read_failure_and_loader_failure(self):
        for fault in ["READ_FAIL=loaded", "LOADER_RC=7"]:
            with self.subTest(fault=fault):
                result = self.run_shell(f'''
printf 'fs.file-max = 262144\\n' > "$CONF_FILE"
OVERRIDE=2097152
{fault}
if apply_and_verify; then exit 80; else rc=$?; fi
[[ {1 if fault.startswith('READ') else 7} -eq $rc ]]
''')
                self.assertNotIn("SUCCESS", result.stdout)

    def test_other_keys_remain_strict(self):
        for value in ["9", "11"]:
            with self.subTest(value=value):
                self.run_shell(f'''
printf 'fs.file-max = 262144\\nvm.swappiness = 10\\n' > "$CONF_FILE"
OVERRIDE=2097152 OTHER_OVERRIDE={value}
if apply_and_verify; then exit 80; fi
''')

    def test_transaction_success(self):
        self.run_shell(r'''
OVERRIDE=2097152
configure_network
[[ $(cat "$PWD/fs.file-max") = 2097152 ]]
[[ $(config_targets "$CONF_FILE") = $'fs.file-max=262144\nvm.swappiness=10' ]]
''')

    def test_transaction_failures_restore_config_and_runtime(self):
        for fault in ["OVERRIDE=131072", "OVERRIDE=invalid", "OVERRIDE=''",
                      "OVERRIDE=2097152 LOADER_RC=7", "READ_FAIL=loaded",
                      "OVERRIDE=2097152 OTHER_OVERRIDE=11"]:
            with self.subTest(fault=fault):
                result = self.run_shell(f'''
printf 'original\\n' > "$CONF_FILE"
printf 'legacy\\n' > "$LEGACY_CONF_FILE"
{fault}
if configure_network; then exit 80; fi
[[ $(cat "$CONF_FILE") = original && $(cat "$LEGACY_CONF_FILE") = legacy ]]
[[ $(cat "$PWD/fs.file-max") = 262144 && $(cat "$PWD/vm.swappiness") = 60 ]]
[[ -e "$PWD/loaded" && -e "$PWD/restored" ]]
[[ -z $(compgen -G "$CONF_FILE.runtime.*") ]]
''')
                self.assertNotIn("SUCCESS", result.stdout)


if __name__ == "__main__":
    unittest.main()
