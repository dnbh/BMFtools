#ifndef BMF_INFER_H
#define BMF_INFER_H
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <zlib.h>
#include <tgmath.h>
#include <unordered_map>
#include <algorithm>
#include <functional>
#include "htslib/sam.h"
#include "include/sam_opts.h"
#include "include/bam.h" // for bam_get_library
#include "include/igamc_cephes.h" // for igamc
#include "dlib/cstr_util.h"
#include "dlib/sort_util.h"
#include "dlib/bam_util.h"
#include "bmf_rsq.h"

namespace BMF {
    extern void resize_stack(tmp_stack_t *stack, size_t n);
    //extern std::string bam2cppstr(bam1_t *b);
    // In this prototype, we're ignoring the alignment stop, though it should likely be expanded to include it.
} /* namespace BMF */

#endif /* BMF_INFER_H */