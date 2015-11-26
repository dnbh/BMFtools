#include "err_calc.h"

int min_obs = 200;

void err_usage_exit(FILE *fp, int retcode)
{
	fprintf(fp, "Usage: Not written\n"
			"bmftools err -o <out.tsv> <reference.fasta> <input.csrt.bam>\n"
			"Opts:\n\t-h/-?\tThis helpful help menu!\n");
	exit(retcode);
}

void err_report(FILE *fp, errcnt_t *e)
{
	fprintf(fp, "{\n{\"total_read\": %lu},\n{\"total_skipped\": %lu},\n", e->nread, e->nskipped);
	uint64_t n_obs = 0, n_err = 0;
	for(int i = 0; i < 4; ++i) {
		for(int j = 0; j < nqscores; ++j) {
			for(int k = 0; k < e->l; ++k) {
				n_obs += e->obs[i][j][k];
				n_err += e->err[i][j][k];
				if(e->obs[i][j][k] >= min_obs) {
					e->rates[i][j][k] = (double)e->err[i][j][k] / e->obs[i][j][k];
				}
			}
		}
	}
	fprintf(fp, "{\"total_error\": %lf},\n{\"total_obs\": %lu},\n{\"total_err\": %lu}",
			(double)n_err / n_obs, n_obs, n_err);
	fprintf(fp, "}");
	return;
}

static inline int bamseq2i(uint8_t seqi) {
	switch(seqi) {
	case HTS_A:
		return 0;
	case HTS_C:
		return 1;
	case HTS_G:
		return 2;
	default: // HTS_T, since HTS_N was already checked for
		return 3;
	}
}

void err_core(samFile *fp, bam_hdr_t *hdr, bam1_t *b, faidx_t *fai, errcnt_t *e)
{
	int r, len;
	int32_t last_tid = -1;
	char *ref; // Will hold the sequence for a chromosome
	while((r = sam_read1(fp, hdr, b)) != -1) {
		if(b->core.flag & 2816 || b->core.tid < 0) { // UNMAPPED, SECONDARY, SUPPLEMENTARY, QCFAIL
			++e->nskipped;
			continue;
		}
		const uint8_t *seq = (uint8_t *)bam_get_seq(b);
		const uint8_t *qual = (uint8_t *)bam_get_qual(b);
		const uint32_t *cigar = bam_get_cigar(b);
		if(++e->nread % 1000000)
			fprintf(stderr, "[%s] Records read: %lu.\n", __func__, e->nread);
		if(b->core.tid != last_tid) {
			free(ref);
			ref = fai_fetch(fai, hdr->target_name[b->core.tid], &len);
			last_tid = b->core.tid;
		}
		// rc -> read count
		// fc -> reference base count
		int i, ind, r_ind, rc, fc;
		const int32_t pos = b->core.pos;
		for(i = 0, rc = 0, fc = 0; i < b->core.n_cigar; ++i) {
			uint8_t s;
			const uint32_t op = cigar[i];
			const uint32_t len = bam_cigar_oplen(op);
			switch(bam_cigar_op(op)) {
			case BAM_CMATCH:
				for(ind = 0; ind < len; ++ind) {
					s = bam_seqi(seq, ind + rc);
					if(s == HTS_N) continue;
					++e->obs[bamseq2i(s)][qual[ind + rc - 2]][ind + rc];
					if(seq_nt16_table[(int)ref[pos + fc + ind]] != s)
						++e->err[bamseq2i(s)][qual[ind + rc - 2]][ind + rc];
				}
			case BAM_CEQUAL:
			case BAM_CDIFF:
				rc += len;
				fc += len;
				break;
			case BAM_CSOFT_CLIP:
			case BAM_CHARD_CLIP:
			case BAM_CINS:
				rc += len;
				break;
			case BAM_CREF_SKIP:
			case BAM_CDEL:
				fc += len;
				break;
			// Default: break
			}
		}
	}
	if(ref) free(ref);
	return;
}

int err_main(int argc, char *argv[])
{
	samFile *fp;
	bam_hdr_t *header;
	int c;
	char outpath[500] = "";

	if(argc < 2) {
		err_usage_exit(stderr, EXIT_FAILURE);
	}

	if(strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) err_usage_exit(stderr, EXIT_SUCCESS);

	while ((c = getopt(argc, argv, "o:h?")) >= 0) {
		switch (c) {
		case 'o': strcpy(outpath, optarg); break;
		case '?':
		case 'h':
			err_usage_exit(stderr, EXIT_SUCCESS);
		default:
			err_usage_exit(stderr, EXIT_FAILURE);
		}
	}

	FILE *ofp = NULL;
	ofp = (outpath[0]) ? fopen(outpath, "w"): stdout;

	if (argc != optind+2)
		err_usage_exit(stderr, EXIT_FAILURE);

	faidx_t *fai = fai_load(argv[optind]);

	fp = sam_open(argv[optind + 1], "r");
	if (fp == NULL) {
		fprintf(stderr, "[famstat_err_main]: Cannot open input file \"%s\"", argv[optind]);
		exit(EXIT_FAILURE);
	}

	header = sam_hdr_read(fp);
	if (header == NULL) {
		fprintf(stderr, "[famstat_err_main]: Failed to read header for \"%s\"\n", argv[optind]);
		exit(EXIT_FAILURE);
	}
	// Get read length from the first read
	bam1_t *b = bam_init1();
	c = sam_read1(fp, header, b);
	errcnt_t *e = errcnt_init((size_t)b->core.l_qseq);
	sam_close(fp);
	fp = sam_open(argv[optind], "r");
	err_core(fp, header, b, fai, e);
	err_report(ofp, e);
	bam_destroy1(b);
	bam_hdr_destroy(header);
	sam_close(fp);
	errcnt_destroy(e);
	fclose(ofp);
	return 0;
}
