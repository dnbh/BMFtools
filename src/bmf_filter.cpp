#include "dlib/bam_util.h"
#include "dlib/bed_util.h"
#include <getopt.h>
#include <functional>

int usage(char **argv, int retcode=EXIT_FAILURE) {
    fprintf(stderr, "bmftools %s <-l output_compression_level> in.bam out.bam\n"
                    "Use - for stdin or stdout.\n", argv[0]);
    return retcode;
}

struct opts {
    uint32_t minFM:14;
    uint32_t v:1;
    uint32_t skip_flag:16;
    uint32_t require_flag:16;
    uint32_t minMQ:8;
    khash_t(bed) *bed;
};

#define TEST(b, options) \
        (\
             bam_itag(b, "FM") < (int)((opts *)options)->minFM ||\
             b->core.qual < ((opts *)options)->minMQ ||\
             (b->core.flag & ((opts *)options)->skip_flag) ||\
             ((b->core.flag & ((opts *)options)->require_flag) == 0) ||\
             !bed_test(b, ((opts *)options)->bed)\
        )

int bam_test(bam1_t *b, void *options) {
    return ((opts *)options)->v ? !TEST(b, options): TEST(b, options);
}

#undef TEST

int filter_main(int argc, char *argv[]) {
    if(argc < 3) {
        return usage(argv);
    }
    if(strcmp(argv[1], "--help") == 0) {
        return usage(argv, EXIT_SUCCESS);
    }
    int c;
    char out_mode[4] = "wb";
    opts param = {0};
    char *bedpath = NULL;
    while((c = getopt(argc, argv, "b:m:F:f:l:hv?")) > -1) {
        switch(c) {
        case 'b': bedpath = optarg; break;
        case 'm': param.minMQ = strtoul(optarg, NULL, 0); break;
        case 'F': param.skip_flag = strtoul(optarg, NULL, 0); break;
        case 'f': param.require_flag = strtoul(optarg, NULL, 0); break;
        case 'v': param.v = 1; break;
        case 'l': out_mode[2] = atoi(optarg) % 10 + '0'; break;
        case 'h': case '?': return usage(argv, EXIT_SUCCESS);
        }
    }
    if(argc - 2 != optind) {
        LOG_EXIT("Required: precisely two positional arguments (in bam, out bam).\n");
    }
    if(bedpath) {
        // This doesn't properly handle streaming....
        samFile *fp = sam_open(argv[optind], "r");
        bam_hdr_t *hdr = sam_hdr_read(fp);
        sam_close(fp);
        param.bed = parse_bed_hash(bedpath, hdr, 0);
        bam_hdr_destroy(hdr);
    }
    // Actually this function. You can't really apply a null function....
    // Actually create your type for data and then provide it if needed.
    dlib::bam_apply_function(argv[optind], argv[optind + 1], bam_test, (void *)&param, out_mode);
    if(param.bed) bed_destroy_hash((void *)param.bed);
    return EXIT_SUCCESS;
}

