# cython: c_string_type=str, c_string_encoding=ascii
# cython: profile=True, cdivision=True, cdivision_warnings=True

from cytoolz import memoize
from math import log10 as mlog10
from .BCVCF import IterativeVCFFile
from .Probability import ConfidenceIntervalAAF, GetCeiling
from .SNVUtils import HeaderFilterDict, HeaderFunctionCallLine
from operator import methodcaller as mc
from subprocess import check_output
from utilBMF.ErrorHandling import IllegalArgumentError, ThisIsMadness
from array import array
import cStringIO
import cython
import logging
import math
import numpy as np
import operator
import pysam
import shlex
import subprocess
import sys
import uuid
from utilBMF.HTSUtils import (printlog as pl,
                              NameSortAndFixMate, makeinfodict,
                              MakeVCFProxyDeaminationFilter,
                              __version__ as BMFVersion)
cimport pysam.TabProxies
cimport numpy as np
cimport cython
from utilBMF.HTSUtils cimport cystr


"""
Contains utilities relating to FFPE and amplicon sequencing
"""


@cython.locals(primerLen=int, fixmate=cython.bint)
def PrefilterAmpliconSequencing(inBAM, primerLen=20, outBAM="default",
                                fixmate=True):
    """
    This program outputs a BAM file which eliminates potential mispriming
    events from the input BAM file.
    """
    if(outBAM == "default"):
        outBAM = ".".join(inBAM.split(".")[0:-1] + ["amplicon",
                                                    "filt", "bam"])
    pl("Primer length set to %s for prefiltering." % primerLen)
    pl("OutBAM: %s" % outBAM)
    pl("fixmate: %s" % fixmate)
    tempFile = str(uuid.uuid4().get_hex().upper()[0:8]) + ".bam"
    inHandle = pysam.AlignmentFile(inBAM, "rb")
    outHandle = pysam.AlignmentFile(tempFile, "wb", template=inHandle)
    for rec in inHandle:
        tempQual = rec.qual[primerLen:]
        rec.seq = rec.seq[primerLen:]
        rec.qual = tempQual
        if(rec.is_reverse):
            rec.pos -= primerLen
        else:
            rec.pos += primerLen
        outHandle.write(rec)
    inHandle.close()
    outHandle.close()
    if(fixmate):
        newTemp = NameSortAndFixMate(tempFile, sortAndIndex=True)
        subprocess.check_call(["mv", newTemp, outBAM])
    return outBAM


@memoize
@cython.returns(double)
def getFreq(pysam.TabProxies.VCFProxy rec, cystr base="d"):
    """
    Returns allele frequency for a tabix VCF Proxy made from SNVCrawler.
    """
    return float(dict([i.split(">") for i in
                       makeinfodict(rec)["MAFS"].split(",")])[base])


cdef dict getFreqDict(pysam.TabProxies.VCFProxy rec):
    cdef cystr i, x, y
    return {x: float(y) for x, y in i.split(">") for
            i in makeinfodict(rec)["MAFS"].split(",")}


cdef dict getFreqDictFromInfoDict(dict InfoDict):
    cdef cystr i, x, y
    return {x: float(y) for x, y in i.split(">") for
            i in InfoDict["MAFS"].split(",")}


@cython.returns(double)
def GetTabixDeamFreq(cystr inVCF):
    """
    Gets deamination frequency for a tabixed VCF file, under the assumption
    that the majority of C-T/G-A calls at low frequencies which are not
    ablated by family demultiplexing are due to formalin fixation.
    """
    cdef int atCounts, gcCounts
    cdef pysam.TabProxies.VCFProxy rec
    cdef float freq
    cdef dict mid, freqDict
    atCounts = 0
    gcCounts = 0
    a = pysam.tabix_iterator(open(inVCF, "rb"), pysam.asVCF())
    for rec in a:
        mid = makeinfodict(rec)
        freqDict = getFreqDictFromInfoDict(mid)
        if(mid["CONS"] == "C" and
           freqDict["T"] / freqDict["C"] < 0.15 and
           rec.alt == "T"):
            atCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["T"])
            gcCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["C"])
        if(mid["CONS"] == "G" and
           freqDict["A"] / freqDict["G"] < 0.15 and
           rec.alt == "A"):
            atCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["A"])
            gcCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["G"])
        if(rec.ref == "C" and freqDict["T"] < 0.25 and
           freqDict["C"] >= 0.3 and rec.alt == "T"):
            atCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["T"])
            gcCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["C"])
        if(rec.ref == "G" and freqDict["A"] < 0.25 and
           freqDict["G"] >= 0.3 and rec.alt == "A"):
            atCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["A"])
            gcCounts += int(dict([i.split(">") for
                                  i in mid["MACS"].split(",")])["G"])
    freq = (1. * atCounts) / gcCounts
    print("Final atCounts: %s" % atCounts)
    print("Final gcCounts: %s" % gcCounts)
    print("Est deam freq: %s" % (freq))
    return freq


@cython.locals(pVal=np.longdouble_t, DOC=int,
               maxFreqNoise=np.longdouble_t, ctfreq=np.longdouble_t,
               AAF=np.longdouble_t, recordsPerWrite=int)
def TabixDeamFilter(inVCF, pVal=0.001, ctfreq=0.006,
                    recordsPerWrite=5000, outVCF="default"):
    """
    If observed AAF is greater than the upper limit of the confidence window
    with a given P-Value, the variant is permitted to stay.
    Otherwise, DeaminationNoise replaces PASS or is appended to other filters.
    """
    pl("C-T/G-A frequency set to %s" % ctfreq)
    inHandle = pysam.tabix_iterator(open(inVCF, "rb"), pysam.asVCF())
    if(outVCF == "default"):
        outVCF = ".".join(inVCF.split(".")[0:-2] + ["ctfilt", "vcf"])
    headerStringIO = cStringIO.StringIO()
    headerStringIO.write(check_output("zcat %s | head -n 2000" % inVCF,
                                      shell=True))
    headerStringIO.reset()
    headerLines = IterativeVCFFile(headerStringIO).header
    del headerStringIO
    pl("TabixDeamFilter called. inVCF: %s. outVCF: %s." % (inVCF,
                                                           outVCF))
    if(not isinstance(outVCF, file)):
        outHandle = open(outVCF, "w")
    else:
        outHandle = outVCF
    ohw = outHandle.write
    mfdnpStr = str(int(-10 * mlog10(pVal)))
    functionCall = ("FilterByDeaminationFreq(%s, pVal=%s, " % (inVCF, pVal) +
                    "ctfreq=%s, recordsPerWrite=" % ctfreq +
                    "%s). BMFTools version: %s" % (recordsPerWrite,
                                                   BMFVersion))
    headerLines.insert(-1, str(HeaderFunctionCallLine(functionCall)))
    ohw("\n".join(headerLines) + "\n")
    FilterFn = MakeVCFProxyDeaminationFilter(ctfreq, conf=pVal,
                                             key="MFDNP",
                                             value=mfdnpStr)
    recordsArray = []
    for rec in inHandle:
        recordsArray.append(FilterFn(rec))
        if(len(recordsArray) >= recordsPerWrite):
            outHandle.write("\n".join(map(str, recordsArray)) + "\n")
            recordsArray = []
    outHandle.write("\n".join(map(str, recordsArray)) + "\n")
    outHandle.flush()
    outHandle.close()
    return outVCF
