import unittest
from compare_captures import summarize


class ComparisonTests(unittest.TestCase):
    def record(self, case, duration, count=35):
        return dict(case=case, coverage={'nodes': count}, metrics={key: duration for key in
            ('tree_ready_ms', 'working_preview_ready_ms', 'preview_ready_ms', 'full_complete_ms')})

    def test_incomplete_coverage_cannot_be_called_equivalent(self):
        result = summarize([self.record('before', 100), self.record('after', 50, 34)])
        self.assertFalse(result['coverage_equal'])

    def test_slow_outlier_is_retained(self):
        result = summarize([self.record('before', 100), self.record('after', 80),
                            self.record('after', 90), self.record('after', 300)])
        metric = result['metrics']['full_complete_ms']
        self.assertEqual(metric['samples']['after'], [80, 90, 300])
        self.assertEqual(metric['after_ms'], 90)
        self.assertEqual(metric['reduction_percent'], 10)

    def test_one_sided_partial_series_has_no_speed_claim(self):
        self.assertEqual(summarize([self.record('before', 100)])['metrics'], {})


if __name__ == '__main__':
    unittest.main()
