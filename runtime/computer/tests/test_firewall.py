import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_supervisor.firewall import CONTROL_PORTS, PROXY_PORT, rules  # noqa: E402


class FirewallRules(unittest.TestCase):
    def test_agent_loopback_only_and_control_ports_closed(self):
        r = rules(10001)
        text = [" ".join(x) for x in r]
        self.assertEqual(len(r), 4)
        # 1) portas de controle rejeitadas ANTES da regra de loopback; o proxy não está na lista
        self.assertIn("--uid-owner 10001", text[0])
        self.assertIn("8790,8765,5900", text[0])
        self.assertNotIn(str(PROXY_PORT), text[0].split("--dports")[1])
        # 2) resolvedor embutido do Docker fechado
        self.assertIn("-d 127.0.0.11/32", text[1])
        self.assertTrue(text[1].endswith("-j REJECT"))
        # 3) loopback permitido só para 127.0.0.0/8
        self.assertIn("-o lo -d 127.0.0.0/8", text[2])
        self.assertTrue(text[2].endswith("-j ACCEPT"))
        # 4) todo o resto do agente (rede do Docker, host, metadata, internet, DNS) rejeitado
        self.assertTrue(text[3].endswith("-j REJECT --reject-with icmp-port-unreachable"))
        self.assertNotIn("-d", text[3].split())

    def test_every_rule_is_scoped_to_the_agent_uid(self):
        for rule in rules(4242) + rules(4242, ipv6=True):
            self.assertIn("--uid-owner", rule)
            self.assertEqual(rule[rule.index("--uid-owner") + 1], "4242")

    def test_ipv6_rejects_everything_from_the_agent(self):
        self.assertEqual(rules(1, ipv6=True), [["-A", "OUTPUT", "-m", "owner", "--uid-owner", "1", "-j", "REJECT"]])

    def test_control_ports_are_the_published_runtime_and_vnc_ports(self):
        self.assertEqual(set(CONTROL_PORTS), {8790, 8765, 5900})


if __name__ == "__main__":
    unittest.main()
