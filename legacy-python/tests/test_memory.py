import unittest

from headroom import memory
from tests.helpers import fixture


class TestMemoryParsers(unittest.TestCase):
    def test_memsize(self):
        self.assertEqual(memory.parse_memsize(fixture("memsize.txt")), 16 * 1024**3)

    def test_vm_stat(self):
        page_size, counts = memory.parse_vm_stat(fixture("vm_stat.txt"))
        self.assertEqual(page_size, 16384)
        self.assertEqual(counts["Pages free"], 246993)
        self.assertEqual(counts["Pages inactive"], 226495)
        self.assertEqual(counts["Pages speculative"], 57026)
        self.assertEqual(counts["Pages purgeable"], 21455)
        self.assertEqual(counts["Pages occupied by compressor"], 32278)
        self.assertEqual(counts["Translation faults"], 51755573)  # quoted key

    def test_estimate_available(self):
        page_size, counts = memory.parse_vm_stat(fixture("vm_stat.txt"))
        expected = (246993 + 226495 + 57026 + 21455) * 16384
        self.assertEqual(memory.estimate_available(page_size, counts), expected)
        self.assertEqual(memory.compressed_bytes(page_size, counts), 32278 * 16384)

    def test_vm_stat_no_header(self):
        with self.assertRaises(ValueError):
            memory.parse_vm_stat("Pages free: 1.\n")

    def test_swapusage(self):
        swap = memory.parse_swapusage(fixture("swapusage.txt"))
        self.assertEqual(swap["total"], 2048 * 1024**2)
        self.assertEqual(swap["used"], 667 * 1024**2)
        self.assertEqual(swap["free"], 1381 * 1024**2)

    def test_swapusage_zero(self):
        swap = memory.parse_swapusage(
            "vm.swapusage: total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)")
        self.assertEqual(swap["used"], 0)

    def test_pressure(self):
        self.assertEqual(memory.parse_pressure("1\n"), "normal")
        self.assertEqual(memory.parse_pressure("2"), "warning")
        self.assertEqual(memory.parse_pressure("4"), "critical")
        self.assertEqual(memory.parse_pressure("7"), "unknown")
        self.assertEqual(memory.parse_pressure(""), "unknown")


if __name__ == "__main__":
    unittest.main()
