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

KHASH_MAP_INIT_INT64(fm, uint64_t)
KHASH_MAP_INIT_INT64(rc, uint64_t)

int RVWarn = 1;

int frac_usage_exit(FILE *fp, int code) {
	return 0;
}


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

static inline void print_hashstats(famstats_t *stats)
{
	fprintf(stdout, "#Family size\tNumber of families\n");
	for(stats->ki = kh_begin(stats->fm); stats->ki != kh_end(stats->fm); ++stats->ki) {
		if(!kh_exist(stats->fm, stats->ki))
			continue;
		fprintf(stdout, "%"PRIu64"\t%"PRIu64"\n", kh_key(stats->fm, stats->ki), kh_val(stats->fm, stats->ki));
	}
	fprintf(stderr, "#RV'd in family\tNumber of families\n");
	for(stats->ki = kh_begin(stats->rc); stats->ki != kh_end(stats->rc); ++stats->ki) {
		if(!kh_exist(stats->rc, stats->ki))
			continue;
		fprintf(stderr, "%"PRIu64"\t%"PRIu64"\n", kh_key(stats->rc, stats->ki), kh_val(stats->rc, stats->ki));
	}
	return;
}

static inline void print_stats(famstats_t *stats)
{
	fprintf(stderr, "#Number passing filters: %"PRIu64".\n", stats->n_pass);
	fprintf(stderr, "#Number failing filters: %"PRIu64".\n", stats->n_fail);
	fprintf(stderr, "#Summed FM (total founding reads): %"PRIu64".\n", stats->allfm_sum);
	fprintf(stderr, "#Summed FM (total founding reads), (FM > 1): %"PRIu64".\n", stats->realfm_sum);
	fprintf(stderr, "#Summed RV (total reverse-complemented reads): %"PRIu64".\n", stats->allrc_sum);
	fprintf(stderr, "#Summed RV (total reverse-complemented reads), (FM > 1): %"PRIu64".\n", stats->realrc_sum);
	fprintf(stderr, "#RV fraction for all read families: %lf.\n", (double)stats->allrc_sum / (double)stats->allfm_sum);
	fprintf(stderr, "#RV fraction for real read families: %lf.\n", (double)stats->realrc_sum / (double)stats->realfm_sum);
	fprintf(stderr, "#Mean Family Size (all)\t%lf\n", (double)stats->allfm_sum / (double)stats->allfm_counts);
	fprintf(stderr, "#Mean Family Size (real)\t%lf\n", (double)stats->realfm_sum / (double)stats->realfm_counts);
	print_hashstats(stats);
}

static inline void tag_test(uint8_t *data, const char *tag)
{
	if(data)
		return;
	fprintf(stderr, "Required bam tag '%s' not found. Abort mission!\n", tag);
	exit(EXIT_FAILURE);
}


static inline void famstat_loop(famstats_t *s, bam1_t *b, famstat_settings_t *settings)
{
	++s->n_pass;
	uint8_t *data;
	data = bam_aux_get(b, "FM");
	tag_test(data, "FM");
	int FM = bam_aux2i(data);
#if DBG
	fprintf(stderr, "FM tag: %i.\n", FM);
#endif
	if(b->core.flag & 2944 || b->core.qual < settings->minMQ || FM < settings->minFM) {
		++s->n_fail;
		return;
		// Skips supp/second/read2/qc fail/marked duplicate
		// 2944 is equivalent to BAM_FSECONDARY | BAM_FSUPPLEMENTARY | BAM_QCFAIL | BAM_FISREAD2
	}
	data = bam_aux_get(b, "RV");
	if(!data && RVWarn) {
		RVWarn = 0;
		fprintf(stderr, "[famstat_core]: Warning: RV tag not found. Continue.\n");
	}
	int RV = data ? bam_aux2i(data): 0;
#if DBG
	fprintf(stderr, "RV tag: %i.\n", RV);
#endif
	if(FM > 1) {
		++s->realfm_counts; s->realfm_sum += FM; s->realrc_sum += RV;
	}
	++s->allfm_counts; s->allfm_sum += FM; s->allrc_sum += RV;
	s->ki = kh_get(fm, s->fm, FM);
	if(s->ki == kh_end(s->fm)) {
		s->ki = kh_put(fm, s->fm, FM, &s->khr);
		kh_val(s->fm, s->ki) = 1;
	}
	else {
		++kh_val(s->fm, s->ki);
	}
	s->ki = kh_get(rc, s->rc, RV);
	if(s->ki == kh_end(s->rc)) {
		s->ki = kh_put(rc, s->rc, RV, &s->khr);
		kh_val(s->rc, s->ki) = 1;
	}
	else {
		++kh_val(s->rc, s->ki);
	}
}


famstats_t *famstat_core(samFile *fp, bam_hdr_t *h, famstat_settings_t *settings)
{
	uint64_t count = 0;
	famstats_t *s;
	bam1_t *b;
	int ret;
	s = (famstats_t*)calloc(1, sizeof(famstats_t));
	s->fm = kh_init(fm);
	s->rc = kh_init(rc);
	s->data = NULL;
	b = bam_init1();
	while ((ret = sam_read1(fp, h, b)) >= 0) {
		famstat_loop(s, b, settings);
		if(!(++count % 250000))
			fprintf(stderr, "[famstat_core] Number of records processed: %"PRIu64".\n", count);
	}
	bam_destroy1(b);
	if (ret != -1)
		fprintf(stderr, "[famstat_core] Truncated file? Continue anyway.\n");
	return s;
}

static void usage_exit(FILE *fp, int exit_status)
{
	fprintf(fp, "Usage: famstat <in.bam>\n");
	fprintf(fp, "Subcommands: \nfm\tFamily Size stats\n");
	exit(exit_status);
}

static void fm_usage_exit(FILE *fp, int exit_status)
{
	fprintf(fp, "Usage: famstat fm <opts> <in.bam>\n");
	fprintf(fp, "-m Set minimum mapping quality. Default: 0.\n");
	fprintf(fp, "-f Set minimum family size. Default: 0.\n");
	exit(exit_status);
}

int fm_main(int argc, char *argv[])
{
	samFile *fp;
	bam_hdr_t *header;
	famstats_t *s;
	int c;


	famstat_settings_t *settings = (famstat_settings_t *)calloc(1, sizeof(famstat_settings_t));
	settings->minMQ = 0;
	settings->minFM = 0;

	while ((c = getopt(argc, argv, "m:f:h")) >= 0) {
		switch (c) {
		case 'm':
			settings->minMQ = atoi(optarg); break;
			break;
		case 'f':
			settings->minFM = atoi(optarg); break;
			break;
		case 'h':
			usage_exit(stderr, EXIT_SUCCESS);
		default:
			usage_exit(stderr, EXIT_FAILURE);
		}
	}
	fprintf(stderr, "[famstat_main]: Running main with minMQ %i and minFM %i.\n", settings->minMQ, settings->minFM);

	if (argc != optind+1) {
		if (argc == optind) usage_exit(stdout, EXIT_SUCCESS);
		else usage_exit(stderr, EXIT_FAILURE);
	}
	fp = sam_open(argv[optind], "r");
	if (fp == NULL) {
		fprintf(stderr, "[famstat_main]: Cannot open input file \"%s\"", argv[optind]);
		exit(EXIT_FAILURE);
	}

	header = sam_hdr_read(fp);
	if (header == NULL) {
		fprintf(stderr, "[famstat_main]: Failed to read header for \"%s\"\n", argv[optind]);
		exit(EXIT_FAILURE);
	}
	s = famstat_core(fp, header, settings);
	print_stats(s);
	kh_destroy(fm, s->fm);
	kh_destroy(rc, s->rc);
	free(s);
	free(settings);
	bam_hdr_destroy(header);
	sam_close(fp);
	return 0;
}

static inline void frac_loop(bam1_t *b, int minFM, uint64_t *fm_above, uint64_t *fm_total)
{
	uint8_t *data = bam_aux_get(b, "FM");
	tag_test(data, "FM");
	int FM = bam_aux2i(data);
	if(b->core.flag & 2944) {
		return;
		// Skips supp/second/read2/qc fail/marked duplicate
		// 2944 is equivalent to BAM_FSECONDARY | BAM_FSUPPLEMENTARY | BAM_QCFAIL | BAM_FISREAD2
	}
	if(FM >= minFM)
		*fm_above += FM;
	*fm_total += FM;
}


int frac_main(int argc, char *argv[])
{
	samFile *fp;
	bam_hdr_t *header;
	int c;
	uint32_t minFM;

	if(strcmp(argv[1], "--help") == 0) frac_usage_exit(stderr, EXIT_SUCCESS);

	while ((c = getopt(argc, argv, "m:h?")) >= 0) {
		switch (c) {
		case 'm':
			minFM = (uint32_t)atoi(optarg); break;
			break;
		case '?':
		case 'h':
			frac_usage_exit(stderr, EXIT_SUCCESS);
		default:
			frac_usage_exit(stderr, EXIT_FAILURE);
		}
	}
	fprintf(stderr, "[famstat_frac_main]: Running frac main minFM %i.\n", minFM);

	if (argc != optind+1) {
		if (argc == optind) usage_exit(stdout, EXIT_SUCCESS);
		else usage_exit(stderr, EXIT_FAILURE);
	}
	fp = sam_open(argv[optind], "r");
	if (fp == NULL) {
		fprintf(stderr, "[famstat_frac_main]: Cannot open input file \"%s\"", argv[optind]);
		exit(EXIT_FAILURE);
	}

	header = sam_hdr_read(fp);
	if (header == NULL) {
		fprintf(stderr, "[famstat_main]: Failed to read header for \"%s\"\n", argv[optind]);
		exit(EXIT_FAILURE);
	}
	uint64_t fm_above = 0, total_fm = 0, count = 0;
	bam1_t *b = bam_init1();
	while ((c = sam_read1(fp, header, b)) >= 0) {
		frac_loop(b, minFM, &fm_above, &total_fm);
		if(!(++count % 250000))
			fprintf(stderr, "[famstat_frac_core] Number of records processed: %"PRIu64".\n", count);
	}
	fprintf(stderr, "#Fraction of raw reads with >= minFM %i: %f.\n", minFM, (double)fm_above / total_fm);
	bam_destroy1(b);
	bam_hdr_destroy(header);
	sam_close(fp);
	return 0;
}

int main(int argc, char *argv[])
{
	if(argc < 2) {
		usage_exit(stderr, 1);
	}
	if(strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
		usage_exit(stderr, 0);
	}
	if(strcmp(argv[1], "fm") == 0) {
		return fm_main(argc - 1, argv + 1);
	}
	if(strcmp(argv[1], "frac") == 0) {
		return frac_main(argc - 1, argv + 1);
	}
	fprintf(stderr, "Unrecognized subcommand. See usage.\n");
	usage_exit(stderr, 1);
}
