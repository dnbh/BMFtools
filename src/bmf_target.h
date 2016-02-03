#ifndef BMF_TARGET_H
#define BMF_TARGET_H
#include "dlib/compiler_util.h"
#include "dlib/bed_util.h"
#include <getopt.h>

typedef struct {
	uint64_t count;
	uint64_t n_skipped;
	uint64_t target;
} target_counts_t;


target_counts_t target_core(char *bedpath, char *bampath, uint32_t padding, uint32_t minMQ, uint64_t notification_interval);

#endif /* BMF_TARGET_H */
