/*  bmf_depth.cpp -- bmftools depth subcommand


    Modified from bedcov.c

ORIGINAL COPYRIGHT:

    Copyright (C) 2012 Broad Institute.
    Copyright (C) 2013-2014 Genome Research Ltd.

    Author: Heng Li <lh3@sanger.ac.uk>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE. */

#include "bmf_depth.h"


typedef struct {
    htsFile *fp;
    bam_hdr_t *header;
    hts_itr_t *iter;
    uint64_t *raw_counts;
    uint64_t *dmp_counts;
    int minMQ;
    int minFM;
    int requireFP;
    khash_t(depth) *depth_hash;
    uint64_t n_analyzed;
} vaux_t;

static inline char *restrdup(char *dest, char *src)
{
    dest = (char *)realloc(dest, sizeof(char) * (strlen(src) + 1));
    strcpy(dest, src);
    return dest;
}

void depth_usage(int retcode)
{
    fprintf(stderr, "Usage: bmftools depth [options] -b <in.bed> <in1.bam> [...]\n\n");
    fprintf(stderr, "  -Q INT        Only count bases of at least INT quality [0]\n");
    fprintf(stderr, "  -f INT        Only count bases of at least INT Famly size (unmarked reads have FM 1) [0]\n");
    fprintf(stderr, "  -m INT        Max depth. Default: %i.\n", DEFAULT_MAX_DEPTH);
    fprintf(stderr, "  -n INT        Set N for quantile reporting. Default: 4 (quartiles)\n");
    fprintf(stderr, "  -p INT        Number of bases around region to pad in coverage calculations. Default: %i\n", (int)DEFAULT_PADDING);
    fprintf(stderr, "  -s FLAG        Skip reads with an FP tag whose value is 0. (Fail)\n");
    exit(retcode);
}

void write_quantiles(kstring_t *k, uint64_t *sorted_array, size_t region_len, int n_quantiles)
{
    for(int i = 1; i < n_quantiles; ++i) {
        kputl((long)sorted_array[region_len * i / n_quantiles + 1], k);
        if(i != n_quantiles - 1) kputc(',', k);
    }
}

void write_hist(vaux_t **aux, FILE *fp, int n_samples, char *bedpath)
{
    int i;
    unsigned j;
    khiter_t k;
    std::unordered_set<int> keyset;
    fprintf(fp, "##bedpath=%s\n", bedpath);
    fprintf(fp, "##total bed region area: %lu.\n", aux[0]->n_analyzed);
    fprintf(fp, "##Two columns per sample: # bases with coverage >= col1, %% bases with coverage >= col1.\n");
    fprintf(fp, "#Depth");
    for(i = 0; i < n_samples; ++i) fprintf(fp, "\t%s:#Bases\t%s:%%Bases", aux[i]->fp->fn, aux[i]->fp->fn);
    fputc('\n', fp);
    for(i = 0; i < n_samples; ++i)
        for(k = kh_begin(aux[i]->depth_hash); k != kh_end(aux[i]->depth_hash); ++k)
            if(kh_exist(aux[i]->depth_hash, k))
                keyset.insert(kh_key(aux[i]->depth_hash, k));
    std::vector<int>keys(keyset.begin(), keyset.end());
    std::sort(keys.begin(), keys.end());
    keyset.clear();
    std::vector<std::vector<uint64_t>> csums;
    for(i = 0; i < n_samples; ++i) {
        csums.push_back(std::vector<uint64_t>(keys.size()));
        for(j = keys.size() - 1; j != (unsigned)-1; --j) {
            if((k = kh_get(depth, aux[i]->depth_hash, keys[j])) != kh_end(aux[i]->depth_hash))
                csums[i][j] = kh_val(aux[i]->depth_hash, k);
            else csums[i][j] = 0;
            if(j != (unsigned)keys.size() - 1)
                csums[i][j] += csums[i][j + 1];
        }
    }
    for(j = 0; j < keys.size(); ++j) {
        fprintf(fp, "%i", keys[j]);
        for(i = 0; i < n_samples; ++i)
            fprintf(fp, "\t%lu\t%0.4f%%", csums[i][j], (double)csums[i][j] * 100. / aux[i]->n_analyzed);
        fputc('\n', fp);
    }
}

double u64_stdev(uint64_t *arr, size_t l, double mean)
{
    double ret = 0.0, tmp;
    for(unsigned i = 0; i < l; ++i) {
        tmp = arr[i] - mean;
        ret += tmp * tmp;
    }
    return sqrt(ret / (l - 1));
}


static inline int plp_fm_sum(const bam_pileup1_t *stack, int n_plp)
{
    // Check for FM tag.
    uint8_t *data = n_plp ? bam_aux_get(stack[0].b, "FM"): NULL;
    if(!data) return n_plp;
    int ret = 0;
    std::for_each(stack, stack + n_plp, [&ret](const bam_pileup1_t& plp){
        ret += bam_aux2i(bam_aux_get(plp.b, "FM"));
    });
    return ret;
}

static int read_bam(void *data, bam1_t *b)
{
    vaux_t *aux = (vaux_t*)data; // data in fact is a pointer to an auxiliary structure
    int ret;
    for(;;)
    {
        ret = aux->iter? sam_itr_next(aux->fp, aux->iter, b) : sam_read1(aux->fp, aux->header, b);
        if ( ret<0 ) break;
        uint8_t *data = bam_aux_get(b, "FM"), *fpdata = bam_aux_get(b, "FP");
        if ((b->core.flag & (BAM_FUNMAP | BAM_FSECONDARY | BAM_FQCFAIL | BAM_FDUP)) ||
            (int)b->core.qual < aux->minMQ || (data && bam_aux2i(data) < aux->minFM) ||
            (aux->requireFP && fpdata && bam_aux2i(fpdata) == 0))
                continue;
        break;
    }
    return ret;
}

int depth_main(int argc, char *argv[])
{
    gzFile fp;
    kstring_t str;
    kstream_t *ks;
    hts_idx_t **idx;
    vaux_t **aux;
    char **col_names;
    int *n_plp, dret, i, n, c, minMQ = 0;
    uint64_t *counts;
    const bam_pileup1_t **plp;
    int usage = 0, max_depth = DEFAULT_MAX_DEPTH, minFM = 0, n_quantiles = 4, padding = DEFAULT_PADDING, khr;
    int requireFP = 0, n_cols = 0;
    char *bedpath = NULL;
    FILE *histfp = NULL;
    khiter_t k = 0;
    if((argc >= 2 && (strcmp(argv[1], "-h") == 0 || strcmp(argv[1], "--help") == 0)))
        depth_usage(EXIT_SUCCESS);

    if(argc < 4) depth_usage(EXIT_FAILURE);

    while ((c = getopt(argc, argv, "H:Q:b:m:f:n:p:?hs")) >= 0) {
        switch (c) {
        case 'H':
            LOG_INFO("Writing output histogram to '%s'\n", optarg);
            histfp = fopen(optarg, "w");
            break;
        case 'Q': minMQ = atoi(optarg); break;
        case 'b': bedpath = strdup(optarg); break;
        case 'm': max_depth = atoi(optarg); break;
        case 'f': minFM = atoi(optarg); break;
        case 'n': n_quantiles = atoi(optarg); break;
        case 'p': padding = atoi(optarg); break;
        case 's': requireFP = 1; break;
        case 'h': /* fall-through */
        case '?': usage = 1; break;
        }
        if (usage) break;
    }
    if (usage || optind > argc) // Require at least one bam
        depth_usage(EXIT_FAILURE);
    memset(&str, 0, sizeof(kstring_t));
    n = argc - optind;
    fprintf(stderr, "n: %i. argc: %i. optind: %i.\n", n, argc, optind);
    aux = (vaux_t **)calloc(n, sizeof(vaux_t*));
    idx = (hts_idx_t **)calloc(n, sizeof(hts_idx_t*));
    for (i = 0; i < n; ++i) {
        aux[i] = (vaux_t *)calloc(1, sizeof(vaux_t));
        aux[i]->minMQ = minMQ;
        aux[i]->minFM = minFM;
        aux[i]->requireFP = requireFP;
        aux[i]->fp = sam_open(argv[i + optind], "r");
        aux[i]->depth_hash = kh_init(depth);
        if (aux[i]->fp)
            idx[i] = sam_index_load(aux[i]->fp, argv[i + optind]);
        if (aux[i]->fp == 0 || idx[i] == 0) {
            fprintf(stderr, "ERROR: fail to open index BAM file '%s'\n", argv[i + optind]);
            return 2;
        }
        // TODO bgzf_set_cache_size(aux[i]->fp, 20);
        aux[i]->header = sam_hdr_read(aux[i]->fp);
        if (aux[i]->header == NULL) {
            fprintf(stderr, "ERROR: failed to read header for '%s'\n",
                    argv[i+optind+1]);
            return 2;
        }
    }
    if(!bedpath) {
        LOG_EXIT("Bed path required. Abort!\n");
    }
    counts = (uint64_t *)calloc(n, sizeof(uint64_t));
    n_cols = count_lines(bedpath);
    col_names = (char **)calloc(n_cols, sizeof(char *));

    fp = gzopen(bedpath, "rb");
    if(!fp) {
        LOG_EXIT("Could not open bedfile %s. Abort!\n", bedpath);
    }
    ks = ks_init(fp);
    n_plp = (int *)calloc(n, sizeof(int));
    plp = (const bam_pileup1_t **)calloc(n, sizeof(bam_pileup1_t*));
    int line_num = 0;
    // Write header
    // stderr ONLY for this development phase.
    kstring_t hdr_str = {0, 0, NULL};
    ksprintf(&hdr_str, "##NQuintiles=%i\n", n_quantiles);
    ksprintf(&hdr_str, "##minMQ=%i\n", minMQ);
    ksprintf(&hdr_str, "##minFM=%i\n", minFM);
    ksprintf(&hdr_str, "##BMFtools version=%s.\n", VERSION);
    size_t capture_size = 0;
    std::vector<uint64_t> raw_capture_counts = std::vector<uint64_t>((size_t)n);
    std::vector<uint64_t> dmp_capture_counts = std::vector<uint64_t>((size_t)n);
    kstring_t cov_str = {0, 0, NULL};
    while (ks_getuntil(ks, KS_SEP_LINE, &str, &dret) >= 0) {
        char *p, *q;
        int tid, start, stop, pos, region_len, arr_ind;
        double raw_mean, dmp_mean, raw_stdev, dmp_stdev;
        bam_mplp_t mplp;
        std::vector<uint64_t> dmp_sort_array;
        std::vector<uint64_t> raw_sort_array;

        for (p = q = str.s; *p && *p != '\t'; ++p);
        if (*p != '\t') goto bed_error;
        *p = 0; tid = bam_name2id(aux[0]->header, q); *p = '\t';
        if (tid < 0) goto bed_error;
        for (q = p = p + 1; isdigit(*p); ++p);
        if (*p != '\t') goto bed_error;
        *p = 0; start = atoi(q); *p = '\t';
        for (q = p = p + 1; isdigit(*p); ++p);
        if (*p == '\t' || *p == 0) {
            int c = *p;
            *p = 0; stop = atoi(q); *p = c;
        } else goto bed_error;
        // Add padding
        start -= padding, stop += padding;
        if(start < 0) start = 0;
        region_len = stop - start;
        capture_size += region_len;
        for(i = 0; i < n; ++i) {
            aux[i]->dmp_counts = (uint64_t *)realloc(aux[i]->dmp_counts, sizeof(uint64_t) * region_len);
            aux[i]->raw_counts = (uint64_t *)realloc(aux[i]->raw_counts, sizeof(uint64_t) * region_len);
        }
        if(*p == '\t') {
            q = ++p;
            while(*q != '\t' && *q != '\n') ++q;
            int c = *q; *q = '\0';
            col_names[i] = restrdup(col_names[i], p);
            *q = c;
        } else col_names[i] = restrdup(col_names[i], NO_ID_STR);

        for (i = 0; i < n; ++i) {
            if (aux[i]->iter) hts_itr_destroy(aux[i]->iter);
            aux[i]->iter = sam_itr_queryi(idx[i], tid, start, stop);
        }
        mplp = bam_mplp_init(n, read_bam, (void**)aux);
        bam_mplp_set_maxcnt(mplp, max_depth);
        memset(counts, 0, sizeof(uint64_t) * n);
        arr_ind = 0;
        while (bam_mplp_auto(mplp, &tid, &pos, n_plp, plp) > 0) {
            if (pos >= start && pos < stop) {
                for (i = 0; i < n; ++i) {
                    ++aux[i]->n_analyzed;
                    if((k = kh_get(depth, aux[i]->depth_hash, n_plp[i])) == kh_end(aux[i]->depth_hash)) {
                        k = kh_put(depth, aux[i]->depth_hash, n_plp[i], &khr);
                        kh_val(aux[i]->depth_hash, k) = 1;
                    } else ++kh_val(aux[i]->depth_hash, k);
                    counts[i] += n_plp[i];
                    aux[i]->dmp_counts[arr_ind] = n_plp[i];
                    raw_capture_counts[i] += n_plp[i];
                    aux[i]->raw_counts[arr_ind] = plp_fm_sum(plp[i], n_plp[i]);
                    dmp_capture_counts[i] += aux[i]->raw_counts[arr_ind];
                }
                ++arr_ind; // Increment for positions in range.
            }
        }
        /*
         * At this point, the arrays have counts for depth
         * for each position in the region.
         * C. Get quartiles.
         * Do for both raw and dmp.
         */
        kputc('\t', &str);
        kputs(col_names[i], &str);
        dmp_sort_array = std::vector<uint64_t>(region_len);
        raw_sort_array = std::vector<uint64_t>(region_len);
        for(i = 0; i < n; ++i) {
            memcpy(raw_sort_array.data(), aux[i]->raw_counts, region_len * sizeof(uint64_t));
            std::sort(raw_sort_array.begin(), raw_sort_array.end());
            memcpy(dmp_sort_array.data(), aux[i]->dmp_counts, region_len * sizeof(uint64_t));
            std::sort(dmp_sort_array.begin(), dmp_sort_array.end());
            raw_mean = (double)std::accumulate(aux[i]->raw_counts, aux[i]->raw_counts + region_len, 0) / region_len;
            raw_stdev = u64_stdev(aux[i]->raw_counts, region_len, raw_mean);
            dmp_mean = (double)std::accumulate(aux[i]->dmp_counts, aux[i]->dmp_counts + region_len, 0) / region_len;
            dmp_stdev = u64_stdev(aux[i]->dmp_counts, region_len, dmp_mean);
            kputc('\t', &str);
            kputl(counts[i], &str);
            ksprintf(&str, ":%0.4f:%0.4f:%0.4f:", dmp_mean, dmp_stdev, dmp_stdev / dmp_mean);
            write_quantiles(&str, &dmp_sort_array[0], region_len, n_quantiles);
            kputc('|', &str);
            kputl((long)(raw_mean * region_len + 0.5), &str); // Total counts
            ksprintf(&str, ":%0.4f:%0.4f:%0.4f:", raw_mean, raw_stdev, raw_stdev / raw_mean);
            write_quantiles(&str, &raw_sort_array[0], region_len, n_quantiles);
            kputc('\t', &str);
        }
        kputs(str.s, &cov_str);
        kputc('\n', &cov_str);
        bam_mplp_destroy(mplp);
        ++line_num;
        continue;

bed_error:
        fprintf(stderr, "Errors in BED line '%s'\n", str.s);
    }
    for(i = 0; i < n; ++i){
        ksprintf(&hdr_str, "##[%s]Mean DMP Coverage: %f.\n", argv[i + optind], (double)dmp_capture_counts[i] / capture_size);
        ksprintf(&hdr_str, "##[%s]Mean Raw Coverage: %f.\n", argv[i + optind], (double)raw_capture_counts[i] / capture_size);
    }
    for(i = 0; i < n; ++i) {
        // All results from that bam file are listed in that column.
        ksprintf(&hdr_str, "#Contig\tStart\tStop\tRegion Name");
        kputc('\t', &hdr_str);
        kputs(argv[i + optind], &hdr_str);
        ksprintf(&hdr_str, "|DMPReads:DMPMeanCov:DMPStdev:DMPCoefVar:%i-tiles", n_quantiles);
        ksprintf(&hdr_str, "|RawReads:RawMeanCov:RawStdev:RawCoefVar:%i-tiles", n_quantiles);
    }
    puts(hdr_str.s);
    puts(cov_str.s);
    free(hdr_str.s), free(cov_str.s);
    free(n_plp); free(plp);
    ks_destroy(ks);
    gzclose(fp);

    if(histfp) write_hist(aux, histfp, n, bedpath), fclose(histfp);

    for (i = 0; i < n; ++i) {
        if (aux[i]->iter) hts_itr_destroy(aux[i]->iter);
        hts_idx_destroy(idx[i]);
        bam_hdr_destroy(aux[i]->header);
        sam_close(aux[i]->fp);
        cond_free(aux[i]->dmp_counts);
        cond_free(aux[i]->raw_counts);
        kh_destroy(depth, aux[i]->depth_hash);
        cond_free(aux[i]);
    }
    for(i = 0; i < n_cols; ++i) free(col_names[i]);
    free(counts);
    free(col_names);
    free(aux); free(idx);
    free(str.s);
    free(bedpath);
    return(EXIT_SUCCESS);
}
