#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
#
# This script parses the output from running microbench.sh, and
# summarizes, compare and visualize the results via histogram.
#
# Usage: ./parse-microbench.py <logfile1> [logfile2 ...]
#
# When only one log file is given, it will plot histograms to compare the
# non-Landlock performance vs. with-Landlock.  If given multiple files
# (can be more than 2), it compares the Landlock performance across those
# different tests, which would typically be different kernel versions or
# Landlock implementations.
#
# When given multiple files, this script tries to do some statistical
# analysis to determine if there is a statistically significant difference
# between the different test runs.  However in practice this hypothesis
# testing is often overly sensitive to small changes due to the high
# sample size, and so it's a reference only.
#
# Copyright © 2025 Tingmao Wang <m@maowtm.org>

import os
import re
import json

from argparse import ArgumentParser
from dataclasses import dataclass

from typing import List, Tuple

BPF_METRICS = [
    ("landlock_hook_ns", "@latency_landlock_hook"),
    ("open_syscall_ns", "@latency_open_syscall"),
    ("overhead", "@landlock_hook_overhead"),
]

argparser = ArgumentParser(description="Parse JSON output from microbench.sh")
argparser.add_argument(
    "input_file",
    help="Input files to parse. This will typically be a set of outputs that are interesting to compare against.",
    nargs="+",
)

args = argparser.parse_args()
inputs = args.input_file

variant_names = []
tests = {}


def collect_json_lines(input_file) -> List[List[dict]]:
    tests = []
    for line in input_file:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            print(line)
            continue
        if not isinstance(obj, dict):
            print(line)
            continue
        if "landlock" in obj:
            print(line)
        elif obj["type"] == "printf":
            print(obj["data"].strip())

        if "landlock" in obj:
            # new test
            tests.append([obj])
        else:
            if not tests:
                raise ValueError(
                    "input file does not start with a valid test description json line"
                )
            tests[-1].append(obj)
    return tests


@dataclass(eq=True)
class Stats:
    count: int
    avg: float
    min: float
    max: float
    sum_of_squares: float
    median: float
    stddev: float
    batch_count: int
    histogram: List[dict] = None

    def p95_confidence(self) -> Tuple[float, float]:
        # Assuming a normal distribution, 95% confidence interval is approximately
        # mean ± 1.96 * (stddev / sqrt(count))
        # (1.96 is standard normal distribution CDF(0.975))
        if self.count == 0:
            return 0.0
        diff = 1.96 * (self.stddev / (self.count ** 0.5))
        return (self.avg - diff, self.avg + diff)

    def median_from_histogram(self) -> float:
        if not self.histogram:
            return -1
        median_pos = self.count // 2
        curr_seen = 0
        median = None
        for bucket in self.histogram:
            start = bucket["min"]
            end = bucket["max"]
            count = bucket["count"]
            if curr_seen <= median_pos < curr_seen + count:
                median = start + (median_pos - curr_seen) / count * (end - start)
                break
            curr_seen += count
        return median

def process_bpf_metric(name, bpf_data, bpf_data_type) -> Stats:
    if bpf_data_type[name] != "hist":
        raise ValueError(f"Expected {name} to be a histogram")
    hist = bpf_data[name]
    total = sum(bucket["count"] for bucket in hist)
    avg = bpf_data[name + "_avg"]
    if not isinstance(avg, int):
        raise ValueError(f"Expected {name}_avg to be an int")
    min_val = bpf_data[name + "_min"]
    if not isinstance(min_val, int):
        raise ValueError(f"Expected {name}_min to be an int")
    max_val = bpf_data[name + "_max"]
    if not isinstance(max_val, int):
        raise ValueError(f"Expected {name}_max to be an int")
    s2x = bpf_data[name + "_s2x"]
    if not isinstance(s2x, int):
        raise ValueError(f"Expected {name}_s2x to be an int")

    for bucket in hist:
        if "min" not in bucket:
            bucket["min"] = min_val
        if "max" not in bucket:
            bucket["max"] = max_val

    # variance = E[X^2] - (E[X])^2
    var = (s2x / total) - (avg ** 2)
    stddev = var ** 0.5

    s = Stats(
        count=total,
        avg=avg,
        min=min_val,
        max=max_val,
        sum_of_squares=s2x,
        median=-1,
        stddev=stddev,
        batch_count=1,
        histogram=hist,
    )
    s.median = s.median_from_histogram()
    return s

metrics_ordered = ["c_measured_syscall_time_ns"]

def parse_test_jsons(test_jsons: List[dict]) -> dict:
    cstats_lines = [l for l in test_jsons if l["type"] == "cstats"]
    if len(cstats_lines) != 1:
        return None
    cstats = cstats_lines[0]
    bpf_data = {}
    bpf_data_type = {}

    result_metrics = {}

    # Parse chist (C histogram) if present
    chist_lines = [l for l in test_jsons if l["type"] == "chist"]
    c_histogram = None
    if chist_lines:
        c_histogram = chist_lines[0]["buckets"]

    for obj in test_jsons:
        if obj["type"] in ["hist", "map", "stats"]:
            d = obj["data"]
            for k, v in d.items():
                bpf_data[k] = v
                bpf_data_type[k] = obj["type"]

    for metric_name, bpf_map_name in BPF_METRICS:
        if bpf_map_name in bpf_data:
            result_metrics[metric_name] = process_bpf_metric(
                bpf_map_name, bpf_data, bpf_data_type
            )
            if metric_name not in metrics_ordered:
                metrics_ordered.append(metric_name)

    c_stats = Stats(
        count=cstats["ntimes"],
        avg=cstats["mean"],
        min=cstats["min"],
        max=cstats["max"],
        sum_of_squares=cstats["sum_of_squares"],
        median=-1,
        stddev=cstats["stddev"],
        batch_count=1,
        histogram=c_histogram,
    )
    if c_histogram:
        c_stats.median = c_stats.median_from_histogram()
    result_metrics["c_measured_syscall_time_ns"] = c_stats

    return result_metrics


@dataclass(eq=True, frozen=True)
class TestDescription:
    landlock: bool
    dir_depth: int
    nb_extra_rules: int

test_descs_ordered = []

def merge_bpf_histograms(hist1: List[dict], hist2: List[dict]) -> List[dict]:
    # Assume both histograms have the same bucket ranges, except they might
    # start or end from different points.
    #
    # Both min and max are inclusive.
    merged = []
    i, j = 0, 0
    while i < len(hist1) and j < len(hist2):
        b1 = hist1[i]
        b2 = hist2[j]
        if b1["max"] < b2["min"]:
            merged.append(b1)
            i += 1
        elif b2["max"] < b1["min"]:
            merged.append(b2)
            j += 1
        else:
            # Overlapping buckets
            new_bucket = {
                "min": min(b1["min"], b2["min"]),
                "max": max(b1["max"], b2["max"]),
                "count": b1["count"] + b2["count"],
            }
            merged.append(new_bucket)
            i += 1
            j += 1
    while i < len(hist1):
        merged.append(hist1[i])
        i += 1
    while j < len(hist2):
        merged.append(hist2[j])
        j += 1
    return merged

def print_histograms_side_by_side(hist1: List[dict], hist2: List[dict], indent: int) -> None:
    # Make copies to avoid modifying the original lists
    hist1 = list(hist1)
    hist2 = list(hist2)
    i, j = 0, 0

    max_count = max(
        bucket["count"] for bucket in hist1 + hist2
    )
    count_thres = max(1, max_count // 40)

    # Check if there are valid buckets remaining after trimming
    if i >= len(hist1) or j >= len(hist2):
        return

    while i < len(hist1) and hist1[i]["count"] < count_thres and j < len(hist2) and hist2[j]["count"] < count_thres:
        i += 1
        j += 1
    trimed_end = False
    while i < len(hist1) and hist1[-1]["count"] < count_thres and j < len(hist2) and hist2[-1]["count"] < count_thres:
        hist1.pop()
        hist2.pop()
        trimed_end = True

    max_max_digits = max(
        len(str(bucket["max"])) for bucket in hist1[i:] + hist2[j:]
    )
    max_min_digits = max(
        len(str(bucket["min"])) for bucket in hist1[i:] + hist2[j:]
    )

    def format_bucket(bucket: dict) -> str:
        nb_of_stars = int((bucket["count"] / max_count) * 40)
        stars = "#" * nb_of_stars
        return f"[{bucket['min']:>{max_min_digits}} .. {bucket['max']:>{max_max_digits}}]: {stars:<40}"

    placeholder = ' ' * len(format_bucket({"min":0,"max":0,"count":max_count}))

    if i > 0 and j > 0:
        print(f"{' ' * indent}   ...")

    while i < len(hist1) and j < len(hist2):
        b1 = hist1[i]
        b2 = hist2[j]
        if b1["max"] < b2["min"]:
            print(f"{' ' * indent}{format_bucket(b1)}    {placeholder}")
            i += 1
        elif b2["max"] < b1["min"]:
            print(f"{' ' * indent}{placeholder}    {format_bucket(b2)}")
            j += 1
        else:
            print(f"{' ' * indent}{format_bucket(b1)}    {format_bucket(b2)}")
            i += 1
            j += 1
    while i < len(hist1):
        b1 = hist1[i]
        print(f"{' ' * indent}{format_bucket(b1)}    {placeholder}")
        i += 1
    while j < len(hist2):
        b2 = hist2[j]
        print(f"{' ' * indent}{placeholder}    {format_bucket(b2)}")
        j += 1

    if trimed_end:
        print(f"{' ' * indent}   ...")

def merge_results(stats1: Stats, stats2: Stats) -> Stats:
    if stats1.count == 0:
        return stats2
    if stats2.count == 0:
        return stats1
    total_count = stats1.count + stats2.count
    avg = (stats1.avg * stats1.count + stats2.avg * stats2.count) / total_count
    min_val = min(stats1.min, stats2.min)
    max_val = max(stats1.max, stats2.max)
    sum_of_squares = stats1.sum_of_squares + stats2.sum_of_squares
    # var = E[X^2] - (E[X])^2
    var = (sum_of_squares / total_count) - (avg ** 2)
    stddev = var ** 0.5
    batch_count = stats1.batch_count + stats2.batch_count

    s = Stats(total_count, avg, min_val, max_val, sum_of_squares, -1, stddev, batch_count, None)
    if stats1.histogram and stats2.histogram:
        s.histogram = merge_bpf_histograms(stats1.histogram, stats2.histogram)
        s.median = s.median_from_histogram()
    return s

for input_file in inputs:
    with open(input_file, "rt") as f:
        variant_name = re.sub(r"\.\w+$", "", os.path.basename(input_file))
        if variant_name in variant_names:
            raise ValueError(f"Duplicate variant name: {variant_name}")
        variant_names.append(variant_name)
        for test in collect_json_lines(f):
            testd = TestDescription(**test[0])
            if variant_name not in tests:
                tests[variant_name] = {}
            if testd not in test_descs_ordered:
                test_descs_ordered.append(testd)
            if testd not in tests[variant_name]:
                tests[variant_name][testd] = {}
            parsed = parse_test_jsons(test[1:])
            if not parsed:
                continue
            for metric_name, metric_stats in parsed.items():
                if metric_name not in tests[variant_name][testd]:
                    tests[variant_name][testd][metric_name] = metric_stats
                else:
                    tests[variant_name][testd][metric_name] = merge_results(
                        tests[variant_name][testd][metric_name], metric_stats
                    )

base_variant = variant_names[0]
test_variants = variant_names[1:]

def confidence_interval_is_different(
    base_low: float, base_high: float,
    test_low: float, test_high: float
) -> bool:
    return base_low > test_high or test_low > base_high

def get_no_landlock_baseline(variant_tests: dict, dir_depth: int) -> Stats:
    """Find the no-landlock baseline test for a given dir_depth."""
    baseline_desc = TestDescription(landlock=False, dir_depth=dir_depth, nb_extra_rules=0)
    if baseline_desc in variant_tests and "c_measured_syscall_time_ns" in variant_tests[baseline_desc]:
        return variant_tests[baseline_desc]["c_measured_syscall_time_ns"]
    return None

for test_desc in test_descs_ordered:
    print(f"{test_desc}")
    base_stats = tests[base_variant][test_desc]
    print(f"  {base_variant}:")
    for metric_name in metrics_ordered:
        if metric_name not in base_stats:
            print(f"    {metric_name}: no data")
            continue
        base_stat = base_stats[metric_name]
        print(f"    {metric_name}: {base_stat.count} samples ({base_stat.batch_count} trials), "
              f"avg={base_stat.avg:.2f}, min={base_stat.min:.2f}, "
              f"max={base_stat.max:.2f}, median={base_stat.median:.2f}, "
              f"stddev={base_stat.stddev:.2f}")
        base_low, base_high = base_stat.p95_confidence()
        print(f"    95% confidence interval: [{base_low:.2f} .. {base_high:.2f}]")

    # Estimate landlock overhead for non-bpf runs (when landlock=True)
    if test_desc.landlock:
        no_landlock_baseline = get_no_landlock_baseline(tests[base_variant], test_desc.dir_depth)
        if no_landlock_baseline and "c_measured_syscall_time_ns" in base_stats:
            overhead = base_stats["c_measured_syscall_time_ns"].avg / no_landlock_baseline.avg * 100 - 100
            if overhead is not None:
                print(f"  Estimated landlock overhead (vs no-landlock): {overhead:.1f}%")
                # Show histogram comparison between landlock and no-landlock
                # (only if this is not a comparison test to reduce noise)
                if not test_variants:
                    landlock_hist = base_stats["c_measured_syscall_time_ns"].histogram
                    no_landlock_hist = no_landlock_baseline.histogram
                    if landlock_hist and no_landlock_hist:
                        print(f"  Histogram comparison (no-landlock vs landlock):")
                        print_histograms_side_by_side(no_landlock_hist, landlock_hist, indent=4)

    for variant in test_variants:
        if test_desc not in tests[variant]:
            print(f"  {variant}: no data")
            continue
        base_stats = tests[base_variant][test_desc]
        variant_stats = tests[variant][test_desc]
        print(f"  {variant}:")
        for metric_name in metrics_ordered:
            if metric_name not in variant_stats:
                print(f"    {metric_name}: no data")
                continue
            stat = variant_stats[metric_name]
            print(f"    {metric_name}: {stat.count} samples ({stat.batch_count} trials), "
                  f"avg={stat.avg:.2f}, min={stat.min:.2f}, "
                  f"max={stat.max:.2f}, median={stat.median:.2f}, "
                  f"stddev={stat.stddev:.2f}")
            test_low, test_high = stat.p95_confidence()
            print(f"    95% confidence interval: [{test_low:.2f} .. {test_high:.2f}]")
            if metric_name in base_stats:
                base_stat = base_stats[metric_name]
                base_low, base_high = base_stat.p95_confidence()
                if test_high < base_low:
                    change = (base_stat.avg - stat.avg) / base_stat.avg * 100
                    print(f"    ** Improved {change:.1f}% **")
                elif test_low > base_high:
                    change = (stat.avg - base_stat.avg) / base_stat.avg * 100
                    print(f"    ** Worsened {change:.1f}% **")
                else:
                    print("    (No significant difference)")
                if base_stat.histogram and stat.histogram:
                    print_histograms_side_by_side(base_stat.histogram, stat.histogram, indent=6)

        # Estimate landlock overhead for this variant as well
        if test_desc.landlock:
            no_landlock_baseline = get_no_landlock_baseline(tests[variant], test_desc.dir_depth)
            if no_landlock_baseline and "c_measured_syscall_time_ns" in variant_stats:
                overhead = variant_stats["c_measured_syscall_time_ns"].avg / no_landlock_baseline.avg * 100 - 100
                if overhead is not None:
                    print(f"    Estimated landlock overhead (vs no-landlock): {overhead:.1f}%")
                    # Don't show histogram to reduce noise
        print("")
