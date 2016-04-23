#ifndef BMF_TARGET_H
#define BMF_TARGET_H

namespace BMF {
    struct target_counts_t {
        uint64_t count;
        uint64_t n_skipped;
        uint64_t target;
        uint64_t rfm_count;
        uint64_t rfm_target;
    };

    target_counts_t target_core(char *bedpath, char *bampath, uint32_t padding, uint32_t minMQ, uint64_t notification_interval);
} /* namespace BMF */

#endif /* ifndef BMF_TARGET_H */
