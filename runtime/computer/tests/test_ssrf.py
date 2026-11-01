import ipaddress
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from racky_egress.ssrf import (  # noqa: E402
    Blocked, SSRFPolicy, host_block_reason, ip_block_reason, noise_host, parse_ip_literal, split_host_port, strip_userinfo,
)


def policy(mapping=None, **kw):
    table = mapping or {}

    def resolver(host, port):
        if host not in table:
            raise OSError("NXDOMAIN")
        return table[host]

    return SSRFPolicy(resolver=resolver, **kw)


class IPClassification(unittest.TestCase):
    BLOCKED = {
        "127.0.0.1": "loopback", "127.8.8.8": "loopback", "10.0.0.1": "private", "172.16.5.4": "private", "172.31.255.255": "private",
        "192.168.0.1": "private", "100.64.0.1": "cgnat", "100.127.255.254": "cgnat", "169.254.169.254": "link-local",
        "169.254.1.1": "link-local", "224.0.0.1": "multicast", "0.0.0.0": "unspecified", "255.255.255.255": "ipv4-broadcast",
        "198.18.0.1": "benchmark", "100.100.100.200": "cgnat", "::1": "loopback", "::": "unspecified", "fe80::1": "link-local",
        "fc00::1": "ula", "fd12:3456::1": "ula", "ff02::1": "multicast", "fd00:ec2::254": "metadata-v6",
        "::ffff:127.0.0.1": "loopback (embutido em IPv6)", "::ffff:10.1.2.3": "private (embutido em IPv6)",
        "::ffff:169.254.169.254": "link-local (embutido em IPv6)", "64:ff9b::7f00:1": "loopback (embutido em IPv6)",
        "2002:7f00:1::1": "loopback (embutido em IPv6)", "2002:a9fe:a9fe::1": "link-local (embutido em IPv6)",
    }
    PUBLIC = ["1.1.1.1", "8.8.8.8", "93.184.216.34", "172.32.0.1", "172.15.255.255", "100.63.255.255", "100.128.0.1",
              "2606:4700:4700::1111", "2a00:1450:4001::1"]

    def test_blocked(self):
        for text, reason in self.BLOCKED.items():
            with self.subTest(ip=text):
                got = ip_block_reason(ipaddress.ip_address(text))
                self.assertIsNotNone(got, text)
                self.assertTrue(got.startswith(reason.split(" ")[0]) or reason.startswith(got.split(" ")[0]), f"{text}: {got} vs {reason}")

    def test_public(self):
        for text in self.PUBLIC:
            with self.subTest(ip=text):
                self.assertIsNone(ip_block_reason(ipaddress.ip_address(text)))


class Literals(unittest.TestCase):
    def test_sneaky_ipv4_forms(self):
        for form, expected in {"2130706433": "127.0.0.1", "0x7f000001": "127.0.0.1", "0x7f.1": "127.0.0.1", "017700000001": "127.0.0.1",
                               "127.1": "127.0.0.1", "0251.0376.0251.0376": "169.254.169.254", "3232235521": "192.168.0.1",
                               "[::1]": "::1"}.items():
            with self.subTest(form=form):
                self.assertEqual(str(parse_ip_literal(form)), expected)

    def test_mapped_ipv6_literal(self):
        # a representação textual varia entre versões do Python; o que importa é o IPv4 embutido
        self.assertEqual(parse_ip_literal("[::ffff:7f00:1]").ipv4_mapped, ipaddress.ip_address("127.0.0.1"))

    def test_names_are_not_literals(self):
        for name in ["example.com", "localhost", "a.b.c", "abc", "1e3.example.com", "host.docker.internal", "256.256.256.256"]:
            with self.subTest(name=name):
                self.assertIsNone(parse_ip_literal(name))


class PolicyCheck(unittest.TestCase):
    def blocked(self, pol, host, port=80):
        with self.assertRaises(Blocked) as ctx:
            pol.check(host, port)
        return ctx.exception.reason

    def test_literal_and_sneaky(self):
        p = policy()
        for host in ["127.0.0.1", "2130706433", "0x7f.0.0.1", "169.254.169.254", "10.0.0.1", "192.168.1.1", "[::1]", "100.64.1.1",
                     "0251.0376.0251.0376", "::ffff:127.0.0.1"]:
            with self.subTest(host=host):
                self.blocked(p, host)

    def test_public_literal_passes_and_is_pinned(self):
        self.assertEqual(policy().check("1.1.1.1", 443), "1.1.1.1")

    def test_internal_names(self):
        p = policy({"host.docker.internal": ["192.168.65.254"]})
        for host in ["host.docker.internal", "HOST.DOCKER.INTERNAL.", "gateway.docker.internal", "localhost", "foo.localhost",
                     "svc.internal", "printer.local", "metadata.google.internal", "foo.home.arpa"]:
            with self.subTest(host=host):
                self.assertIn(self.blocked(p, host), ("internal-name", "internal-suffix"))

    def test_dns_resolving_to_private_is_blocked(self):
        p = policy({"evil.example": ["10.0.0.5"], "meta.example": ["169.254.169.254"], "lo.example": ["127.0.0.1"], "v6.example": ["fd00::1"]})
        for host in ["evil.example", "meta.example", "lo.example", "v6.example"]:
            with self.subTest(host=host):
                self.blocked(p, host)

    def test_any_bad_answer_blocks_rebinding_mix(self):
        p = policy({"mix.example": ["93.184.216.34", "10.0.0.1"]})
        self.assertEqual(self.blocked(p, "mix.example"), "private")

    def test_public_dns_pins_first(self):
        p = policy({"ok.example": ["93.184.216.34", "93.184.216.35"]})
        self.assertEqual(p.check("ok.example", 443), "93.184.216.34")

    def test_dns_failure_blocks(self):
        self.assertEqual(self.blocked(policy(), "nope.example"), "dns-failure")

    def test_explicit_exception_allows_only_that_range(self):
        p = policy({"origin": ["172.30.0.9"], "other": ["172.31.0.9"]}, allow_cidrs=["172.30.0.0/24"])
        self.assertEqual(p.check("origin", 80), "172.30.0.9")
        self.blocked(p, "other")
        self.blocked(p, "169.254.169.254")
        self.blocked(p, "127.0.0.1")

    def test_allow_hosts(self):
        p = policy({"a.accela.com": ["93.184.216.34"], "b.example.com": ["93.184.216.35"]}, allow_hosts=["*.accela.com"])
        self.assertEqual(p.check("a.accela.com", 443), "93.184.216.34")
        self.assertEqual(self.blocked(p, "b.example.com"), "not-in-allowlist")


class Parsing(unittest.TestCase):
    def test_split_host_port(self):
        self.assertEqual(split_host_port("example.com:8443", 443), ("example.com", 8443))
        self.assertEqual(split_host_port("example.com", 443), ("example.com", 443))
        self.assertEqual(split_host_port("[::1]:8080", 80), ("::1", 8080))
        self.assertEqual(split_host_port("[::1]", 80), ("::1", 80))
        with self.assertRaises(Blocked):
            split_host_port("example.com:99999", 80)
        with self.assertRaises(Blocked):
            split_host_port("example.com:abc", 80)

    def test_userinfo_trick(self):
        # http://93.184.216.34@127.0.0.1/ conecta em 127.0.0.1
        self.assertEqual(strip_userinfo("93.184.216.34@127.0.0.1"), "127.0.0.1")
        self.assertEqual(strip_userinfo("u:p@evil.example:8080"), "evil.example:8080")

    def test_noise(self):
        self.assertTrue(noise_host("update.googleapis.com", ["update.googleapis.com"]))
        self.assertTrue(noise_host("a.doubleclick.net", ["doubleclick.net"]))
        self.assertFalse(noise_host("notdoubleclick.net", ["doubleclick.net"]))
        self.assertFalse(host_block_reason("example.com"))


class DualStackOrdering(unittest.TestCase):
    """F29: AAAA na frente sem rota IPv6 fazia o CONNECT estourar o tempo; IPv4 vem primeiro."""

    def test_ipv4_first(self):
        p = policy({"www.houstontx.gov": ["2606:2800:220:1::1", "93.184.216.34", "2606:2800:220:1::2", "93.184.216.35"]})
        self.assertEqual(p.check_all("www.houstontx.gov", 443), ["93.184.216.34", "93.184.216.35", "2606:2800:220:1::1", "2606:2800:220:1::2"])
        self.assertEqual(p.check("www.houstontx.gov", 443), "93.184.216.34")

    def test_any_private_answer_still_blocks(self):
        with self.assertRaises(Blocked):
            policy({"x.example": ["93.184.216.34", "10.0.0.5"]}).check_all("x.example", 443)


if __name__ == "__main__":
    unittest.main()
