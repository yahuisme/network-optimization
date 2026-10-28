"""Apply only owned settings; no host sysctl writes or initializer entrypoint."""
import unittest
import test_file_max


class ScopeTests(unittest.TestCase):
    run_shell = test_file_max.FileMaxTests.run_shell

    def test_all_generated_parameters_apply_and_read_back(self):
        for memory in (256, 512, 768, 1024, 2048, 4096, 8192):
            with self.subTest(memory=memory):
                self.run_shell(f'TOTAL_MEM={memory}\n' + r'''
BBR_AVAILABLE=true
sysctl_supported() { return 0; }
calculate_parameters
configure_network
[[ $(config_targets "$CONF_FILE" | wc -l) = 29 ]]
[[ $(cat net.ipv4.tcp_congestion_control) = bbr ]]
[[ $(cat net.core.default_qdisc) = fq ]]
[[ $(cat net.ipv4.tcp_rmem) = "8192 262144 $TCP_MEM_MAX" ]]
''')

    def test_parser_and_root_guards_do_not_mutate(self):
        for args, expected in (
            ('--help', 0), ('-h', 0), ('--help extra', 2),
            ('unknown', 2), ("''", 2), ('restore', 1), ('uninstall', 1), ('', 1),
        ):
            with self.subTest(args=args):
                self.run_shell(test_file_max.extract('usage') + '\n' +
                               test_file_max.extract('require_root') + '\n' +
                               test_file_max.extract('pre_flight_checks') + '\n' +
                               test_file_max.extract('main') + r'''
BOLD='' NC='' SCRIPT_VERSION=test
id() { printf '1000\n'; }
modprobe() { touch mutated; }
configure_swap() { touch mutated; }
configure_network() { touch mutated; }
''' + f'''
if (main {args}); then rc=0; else rc=$?; fi
[[ $rc = {expected} && ! -e mutated ]]
''')

    def test_uninstall_leaves_runtime_untouched(self):
        self.run_shell(test_file_max.extract('usage') + '\n' + test_file_max.extract('main') + r'''
BOLD='' NC='' SCRIPT_VERSION=test
require_root() { :; }
printf 'vm.swappiness=10\n' > "$CONF_FILE"
printf 'unchanged\n' > unrelated
sysctl() { printf 'changed\n' > unrelated; return 0; }
(main uninstall)
[[ ! -e "$CONF_FILE" && $(cat unrelated) = unchanged ]]
''')

    def test_restore_loads_only_backup_targets(self):
        self.run_shell(test_file_max.extract('usage') + '\n' + test_file_max.extract('main') + r'''
BOLD='' NC='' SCRIPT_VERSION=test
require_root() { :; }
printf 'vm.swappiness=10\n' > "$CONF_FILE"
printf 'vm.swappiness=30\n' > "$CONF_FILE.bak_test"
(main restore)
[[ $(cat vm.swappiness) = 30 ]]
! grep -q -- '--system' calls
''')

    def test_apply_does_not_reload_unrelated_settings(self):
        self.run_shell(r'''
# A --system loader would touch an unrelated forwarding setting.
printf '0\n' > ip_forward
eval "$(declare -f sysctl | sed '1s/sysctl/previous_sysctl/')"
sysctl() {
    if [[ "$1" = --system ]]; then
        printf '1\n' > ip_forward
        previous_sysctl -p "$CONF_FILE"
    else
        previous_sysctl "$@"
    fi
}
configure_network
[[ $(cat ip_forward) = 0 ]]
''')


if __name__ == '__main__':
    unittest.main()
