#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <getopt.h>
#include <inttypes.h>

#include "htslib/sam.h"
//#include "samtools.h"
#include "khash.h"
#include "ksort.h"


KHASH_MAP_INIT_INT64(fm, uint64_t)
KHASH_MAP_INIT_INT64(rc, uint64_t)

typedef struct interval {
	uint32_t start;
	uint32_t end;
} interval_t;

typedef struct region_set {
	interval_t *intervals;
	uint64_t n;
} region_set_t;

#ifndef cond_free
#define cond_free(var) do {if(var) {free(var); var = NULL;}} while(0)
#endif

typedef struct famstats {
	uint64_t n_pass;
	uint64_t n_fail;
	uint64_t allfm_sum;
	uint64_t allfm_counts;
	uint64_t allrc_sum;
	uint64_t realfm_sum;
	uint64_t realfm_counts;
	uint64_t realrc_sum;
	khash_t(fm) *fm;
	khash_t(rc) *rc;
	khiter_t ki;
	int khr;
	uint8_t *data;
} famstats_t;

typedef struct famstat_settings {
	uint32_t minMQ;
	uint32_t minFM;
} famstat_settings_t;
