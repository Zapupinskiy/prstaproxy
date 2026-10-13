import subprocess
import unittest

from test_status import BASH, ROOT


class SpeedTests(unittest.TestCase):
    def format(self, byte_count, seconds):
        result = subprocess.run([BASH, '-c',
                                 'source "$1/prstaproxy.sh"; format_speed "$2" "$3"',
                                 '_', ROOT.as_posix(), str(byte_count), str(seconds)],
                                capture_output=True, encoding='utf-8')
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_bytes_are_converted_to_kilobits(self):
        self.assertEqual(self.format(2000, 2), '8.0 Кбит/с')
        self.assertEqual(self.format(0, 1), '0.0 Кбит/с')

    def test_unit_boundaries(self):
        self.assertEqual(self.format(999000, 1), '7992.0 Кбит/с')
        self.assertEqual(self.format(1000000, 1), '1.0 МБ/с')
        self.assertEqual(self.format(124000000, 1), '124.0 МБ/с')
        self.assertEqual(self.format(125000000, 1), '1.0 Гбит/с')
        self.assertEqual(self.format(500000000, 2), '2.0 Гбит/с')

    def test_invalid_sample_has_no_speed(self):
        self.assertEqual(self.format(1000, 0), '—')
        self.assertEqual(self.format(-1, 1), '—')
