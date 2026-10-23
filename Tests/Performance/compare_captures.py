#!/usr/bin/env python3
"""Чередующиеся первые захваты двух закреплённых пакетов через настоящий breakpoint.

Принимает сохранённые записи before/after и не управляет приложениями.
Контроль количества/состава ресурсов не позволяет считать неполный захват быстрым.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys


def summarize(records):
    groups = {label: [row for row in records if row['case'] == label] for label in ('before', 'after')}
    metrics = {}
    for name in ('tree_ready_ms', 'working_preview_ready_ms', 'preview_ready_ms', 'full_complete_ms'):
        values = {label: [row['metrics'][name] for row in rows] for label, rows in groups.items()}
        if all(values.values()):
            before, after = [statistics.median(values[label]) for label in ('before', 'after')]
            metrics[name] = dict(before_ms=before, after_ms=after, reduction_percent=(before-after)/before*100,
                                 samples=values)
    coverage = [row['coverage'] for row in records]
    return dict(records=records, metrics=metrics, complete_pairs=min(map(len, groups.values())),
                coverage_equal=not coverage or all(row == coverage[0] for row in coverage),
                limitations=['First capture after app/client restart, not an OS cache flush.',
                             'Resource readiness is not measured GPU presentation.',
                             'All samples, including outliers, are retained.'])



def main():
    parser = argparse.ArgumentParser(description='Summarize recorded capture timings with coverage checks.')
    parser.add_argument('records', type=Path, help='JSON array of before/after capture records')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = summarize(json.loads(args.records.read_text()))
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    if not result['coverage_equal']:
        raise SystemExit('Capture coverage differs; timing comparison is not equivalent.')


if __name__ == '__main__':
    main()
