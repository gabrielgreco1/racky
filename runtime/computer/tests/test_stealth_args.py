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

    def test_lean_flags_are_on_by_default_and_never_disable_webgl(self):
        args = launch_args({})
        self.assertIn("--in-process-gpu", args)
        self.assertEqual(sum(a.startswith("--disable-features=") for a in args), 1)
        self.assertIn("SpareRendererForSitePerProcess", next(a for a in args if a.startswith("--disable-features=")))
        self.assertNotIn("--disable-gpu", args)
        off = launch_args({"RACKY_CHROMIUM_LEAN": "0"})
        self.assertNotIn("--in-process-gpu", off)
        self.assertIn("--disable-features=Translate", off)


if __name__ == "__main__":
    unittest.main()
