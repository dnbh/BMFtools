######################################
# Makefile written by Daniel Baker   #
#     d.nephi.baker@gmail.com        #
######################################

CXXSTD=c++11
CSTD=gnu99
CC=gcc
CXX=g++
#CC=gcc-mp-6
#CXX=g++-mp-6
GIT_VERSION := $(shell git describe --abbrev=4 --always)
WARN = -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers -Wno-unused-result \
       -Wno-unused-function -Wuninitialized -Wunreachable-code -pedantic
SHARED = -fno-builtin-gamma -fno-strict-aliasing -fopenmp
CFLAGS= -DBMF_VERSION=\"$(GIT_VERSION)\" -std=$(CSTD) $(WARN) $(SHARED)
FLAGS= -DBMF_VERSION=\"$(GIT_VERSION)\" -std=$(CXXSTD) $(WARN) $(SHARED)
LD= -lm -lz -lpthread
INCLUDE= -Ihtslib -Iinclude -I.
LIB=
INSTALL=/usr/bin/install -c
THREADS=12
GENOME_PATH=/mounts/genome/human_g1k_v37.fasta

prefix = /usr/local
bindir = $(prefix)/bin
binprefix =

OPT = -finline-functions -O3 -DNDEBUG -flto -fivopts
DB_FLAGS  = -g -fno-inline
PG_FLAGS  = -pg -DNDEBUG -O3

DLIB_SRC = dlib/cstr_util.c dlib/math_util.c dlib/vcf_util.c dlib/io_util.c dlib/bam_util.c dlib/nix_util.c \
		   dlib/bed_util.c dlib/misc_util.c

SOURCES = include/sam_opts.c src/bmf_collapse.c include/igamc_cephes.c lib/hashdmp.c \
		  src/bmf_rsq.c src/bmf_famstats.c include/bedidx.c \
		  src/bmf_err.c \
		  lib/kingfisher.c src/bmf_mark.c src/bmf_cap.c lib/mseq.c lib/splitter.c \
		  src/bmf_main.c src/bmf_target.c src/bmf_depth.c src/bmf_vet.c src/bmf_sort.c src/bmf_stack.c \
		  lib/stack.c src/bmf_filter.c $(DLIB_SRC)

TEST_SOURCES = test/target_test.c test/ucs/ucs_test.c test/tag/array_tag_test.c

TEST_OBJS = $(TEST_SOURCES:.c=.dbo)

P_OBJS = $(SOURCES:.c=.po)
D_OBJS = $(SOURCES:.c=.dbo)
OBJS = $(SOURCES:.c=.o)
DLIB_OBJS = $(DLIB_SRC:.c=.o)


ALL_TESTS=test/ucs/ucs_test marksplit_test hashdmp_test target_test err_test rsq_test
BINS=bmftools
UTILS=bam_count fqc

.PHONY: all clean install tests python mostlyclean hashdmp_test err_test update_dlib util

all: libhts.a $(BINS)


util: $(UTILS)

install: all
	$(INSTALL) bmftools $(bindir)/$(binprefix)bmftools
	$(INSTALL) bmftools_db $(bindir)/$(binprefix)bmftools_db
	$(INSTALL) bmftools_p $(bindir)/$(binprefix)bmftools_p

%.o: %.cpp
	$(CXX) -c $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(OPT) $< -o $@

src/%.o: src/%.cpp cstr_util.o
	$(CXX) -c $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(OPT) $(DLIB_OBJS) $< -o $@

%.o: %.c
	$(CC) -c $(CFLAGS) $(INCLUDE) $(LIB) $(LD) $(OPT) $< -o $@

%.po: %.cpp
	$(CXX) -c $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(PG_FLAGS) $< -o $@

%.po: %.c
	$(CC) -c $(CFLAGS) $(INCLUDE) $(LIB) $(LD) $(PG_FLAGS) $< -o $@

%.dbo: %.cpp
	$(CXX) -c $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(DB_FLAGS) $< -o $@

%.dbo: %.c
	$(CC) -c $(CFLAGS) $(INCLUDE) $(LIB) $(LD) $(DB_FLAGS) $< -o $@


libhts.a:
	+cd htslib && echo "/* Empty config.h */" >> config.h && make -j $(THREADS) && cp libhts.a ../
bmftools_db: $(D_OBJS) libhts.a update_dlib
	$(CXX) $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(DB_FLAGS) $(D_OBJS) libhts.a $(LD) -o bmftools_db
bmftools_p: $(P_OBJS) libhts.a update_dlib
	$(CXX) $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(PG_FLAGS) $(P_OBJS) libhts.a $(LD) -o bmftools_p
bmftools: $(OBJS) libhts.a update_dlib
	$(CXX) $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(OPT) $(OBJS) libhts.a $(LD) -o bmftools

test/ucs/ucs_test: libhts.a $(TEST_OBJS)
	$(CXX) $(FLAGS) $(INCLUDE) $(LIB) $(LD) $(DB_FLAGS) test/ucs/ucs_test.dbo libhts.a -o test/ucs/ucs_test
	cd test/ucs && ./ucs_test && cd ./..
tag_test: $(OBJS) $(TEST_OBJS) libhts.a
	$(CXX) $(FLAGS) $(DB_FLAGS) $(INCLUDE) $(LIB) test/tag/array_tag_test.dbo libhts.a $(LD) -o ./tag_test && ./tag_test
target_test: $(D_OBJS) $(TEST_OBJS) libhts.a
	$(CXX) $(FLAGS) $(DB_FLAGS) $(INCLUDE) $(LIB) dlib/bed_util.dbo src/bmf_target.dbo test/target_test.dbo libhts.a $(LD) -o ./target_test && ./target_test
hashdmp_test: $(BINS)
	cd test/collapse && python hashdmp_test.py && cd ../..
marksplit_test: $(BINS)
	cd test/marksplit && python marksplit_test.py && cd ../..
err_test: $(BINS)
	cd test/err && python err_test.py $(GENOME_PATH) && cd ../..
rsq_test: $(BINS)
	cd test/rsq && python rsq_test.py  && cd ../..

%: util/%.o libhts.a
	$(CC) $(FLAGS) $(INCLUDE) $(LIB) $(OPT) util/$@.o libhts.a $(LD) -o $@


tests: $(BINS) $(ALL_TESTS) test/tag/array_tag_test.dbo
	@echo "Passed all tests!"

fqc: util/fqc.o
	$(CXX) util/fqc.o -I.. -I../htslib -std=c++11 -lz -o fqc -O3


clean: mostlyclean
		cd htslib && make clean && cd ..

update_dlib:
	cd dlib && git checkout v0.3 && cd ..

mostlyclean:
	rm -f *.*o && rm -f bmftools* && rm -f src/*.*o && rm -f dlib/*.*o && \
	rm -f include/*.*o && rm -f lib/*.*o && rm -f $(find ./test -name '*o')
