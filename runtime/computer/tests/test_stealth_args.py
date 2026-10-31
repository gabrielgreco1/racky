"""Flags do Chromium que não denunciam automação (F42)."""
import unittest

from racky_runtime.browser import SCREEN, launch_args


class StealthArgsTests(unittest.TestCase):
    def test_no_flags_that_mark_a_bot(self):
        args = launch_args({})
        self.assertNotIn("--disable-gpu", args)  # sem GPU o WebGL some
        self.assertNotIn("--enable-automation", args)
        self.assertIn("--use-angle=swiftshader", args)
        self.assertIn(f"--window-size={SCREEN[0]},{SCREEN[1]}", args)

    def test_language_follows_the_mac(self):
        args = launch_args({"RACKY_LOCALE": "pt-BR"})
        self.assertIn("--lang=pt-BR", args)
        self.assertIn("--accept-lang=pt-BR,pt,en-US,en", args)
        self.assertIn("--lang=en-US", launch_args({}))


if __name__ == "__main__":
    unittest.main()
