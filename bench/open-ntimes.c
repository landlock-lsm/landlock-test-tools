// SPDX-License-Identifier: GPL-2.0
/*
 * open-ntimes <ntimes> <errno> <path>
 *
 * LL_FS_RO="/" LL_FS_RW="/" ./perf trace -s -e openat -- sandboxer ./open-ntimes 10000000 0 /mnt/1/2/3/4/5/6/7/8/9/
 *
 * Copyright © 2025 Mickaël Salaün <mic@digikod.net>.
 */

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/* Histogram configuration (in nanoseconds) */
#define HIST_MIN 100
#define HIST_STEP 10
#define HIST_MAX 2000

/* Number of histogram buckets - +2 for the open-ended buckets */
#define HIST_BUCKETS ((((HIST_MAX) - (HIST_MIN)) / (HIST_STEP)) + 2)

static bool has_verbose(void)
{
	const char *verbose = getenv("VERBOSE");
	return verbose && strcmp(verbose, "0") != 0;
}

struct stats {
	uint64_t sum;
	uint64_t sum_of_squares;
	uint64_t min;
	uint64_t max;
	uint64_t count;
};

static void add_stat(struct stats *stats, uint64_t value)
{
	stats->sum += value;
	stats->sum_of_squares += value * value;
	stats->count++;
	if (value < stats->min)
		stats->min = value;
	if (value > stats->max)
		stats->max = value;
}

static void print_stats(const struct stats *stats, uint64_t ntimes)
{
	double mean = (double)stats->sum / ntimes;
	/* var = E[X^2] - (E[X])^2 */
	double variance =
		((double)stats->sum_of_squares / ntimes) - (mean * mean);
	double stddev = sqrt(variance);

	printf("{\"type\":\"cstats\",\"ntimes\":%lu,\"mean\":%.4f,\"stddev\":%.4f,"
	       "\"min\":%lu,\"max\":%lu,\"sum_of_squares\":%lu}\n",
	       ntimes, mean, stddev, stats->min, stats->max,
	       stats->sum_of_squares);
}

/*
 * Get the histogram bucket index for a given value.
 */
static int get_hist_bucket(uint64_t value)
{
	if (value < HIST_MIN)
		return 0;
	else if (value >= HIST_MAX)
		return HIST_BUCKETS - 1;
	else
		return (value - HIST_MIN) / HIST_STEP + 1;
}

/*
 * Add a sample to the histogram.
 */
static void add_to_histogram(uint64_t *histogram, uint64_t value)
{
	int bucket = get_hist_bucket(value);
	if (bucket >= 0 && bucket < HIST_BUCKETS)
		histogram[bucket]++;
}

/*
 * Print the histogram in JSON format.
 */
static void print_histogram(const uint64_t *histogram, const struct stats *stats)
{
	printf("{\"type\":\"chist\",\"buckets\":[");
	bool printed_any = false;
	for (int i = 0; i < HIST_BUCKETS; i++) {
		if (printed_any)
			printf(",");
		uint64_t this_min, this_max;
		if (i == 0) {
			this_min = stats->min;
			this_max = HIST_MIN - 1;
		} else if (i == HIST_BUCKETS - 1) {
			this_min = HIST_MAX;
			this_max = stats->max;
		} else {
			this_min = HIST_MIN + (i - 1) * HIST_STEP;
			this_max = this_min + HIST_STEP - 1;
		}
		if (this_min > this_max)
			continue;
		printed_any = true;
		printf("{\"min\":%lu,\"max\":%lu,\"count\":%lu}",
		       this_min, this_max, histogram[i]);
	}
	printf("]}\n");
}

int main(int argc, char *argv[])
{
	ssize_t ntimes, prepare_ntimes;
	int err;
	const char *path;
	bool verbose = has_verbose();
	struct stats stats = {
		.sum = 0,
		.sum_of_squares = 0,
		.min = UINT64_MAX,
		.max = 0,
		.count = 0,
	};
	struct timespec test_start = {}, test_end = {};
	uint64_t nsecs_total;
	uint64_t *histogram;

	if (argc != 4)
		return 1;

	/* Allocate histogram array */
	histogram = calloc(HIST_BUCKETS, sizeof(uint64_t));
	if (!histogram) {
		perror("Failed to allocate histogram");
		return 1;
	}

	ntimes = atoi(argv[1]);
	if (verbose)
		printf("[#] ntimes: %ld\n", ntimes);
	if (ntimes <= 0)
		return 1;

	prepare_ntimes = ntimes / 5;
	if (verbose)
		printf("[#] running open for %ld times to warm up first.\n",
		       prepare_ntimes);

	err = atoi(argv[2]);
	if (verbose)
		printf("[#] expected errno: %d\n", err);

	path = argv[3];
	if (verbose)
		printf("[#] path: %s\n", path);

	for (size_t i = 0; i < prepare_ntimes + ntimes; i++) {
		struct timespec start, end;
		int fd;
		uint64_t ns_elapsed;

		if (clock_gettime(CLOCK_MONOTONIC, &start))
			perror("clock_gettime");
		fd = open(path, O_RDONLY);
		if (clock_gettime(CLOCK_MONOTONIC, &end))
			perror("clock_gettime");

		if (fd < 0) {
			if (err != errno) {
				perror("Unexpected error");
				return 1;
			}
		} else {
			if (err) {
				fprintf(stderr, "Unexpected success");
				return 1;
			}
			close(fd);
		}

		ns_elapsed = (end.tv_sec - start.tv_sec) * 1000000000ULL +
			     (end.tv_nsec - start.tv_nsec);

		if (verbose && i == prepare_ntimes) {
			if (clock_gettime(CLOCK_MONOTONIC, &test_start))
				perror("clock_gettime");
			printf("[#] Done warming up.\n");
		}
		if (i >= prepare_ntimes) {
			add_stat(&stats, ns_elapsed);
			add_to_histogram(histogram, ns_elapsed);
		}
	}

	if (verbose) {
		if (clock_gettime(CLOCK_MONOTONIC, &test_end))
			perror("clock_gettime");

		nsecs_total =
			(test_end.tv_sec - test_start.tv_sec) * 1000000000ULL +
			(test_end.tv_nsec - test_start.tv_nsec);

		printf("[#] Total time: %lu ns => %.4f avg\n", nsecs_total,
		       (double)nsecs_total / ntimes);
	}

	print_stats(&stats, stats.count);
	print_histogram(histogram, &stats);
	free(histogram);
	return 0;
}
