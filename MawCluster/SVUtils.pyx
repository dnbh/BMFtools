from utilBMF.HTSUtils import (printlog as pl, ThisIsMadness, FacePalm,
                              ReadPair, ParseBed, SplitSCRead,
                              ReadPairIsDuplex,
                              PysamToChrDict, GetDeletedCoordinates,
                              is_read_softclipped, GetGC2NMapForRead,
                              GetInsertedStrs, ReadOverlapsBed as RIB)

from Bio.Seq import Seq
from collections import defaultdict
from itertools import chain
from numpy import argmax as nargmax
from operator import add as oadd
from operator import attrgetter as oag
from operator import itemgetter as oig
from utilBMF import HTSUtils
import copy
import cython
import cytoolz
import numpy as np
import operator
import pysam
import uuid
cimport numpy as np
cimport cython
cimport pysam.calignmentfile
cfi = chain.from_iterable


cdef class TestClass:
    """
    Testing some of cython's abilities.
    """
    cdef public cython.str text
    cdef public cython.long length

    def __init__(self, inStr):
        self.length = len(inStr)
        self.text = inStr


class XLocSegment:

    """
    Contains evidence regarding a potential translocation. This includes the
    depth of supporting reads, the regions involved, and a list of those reads.
    TODO: Eventually remove the assertions for speed.
    """
    @cython.locals(DOR=cython.long)
    def __init__(self, interval="default", DOR=0,
                 bedIntervals="default"):
        try:
            assert isinstance(bedIntervals[0][0], str) and isinstance(
                bedIntervals[0][1], int)
        except AssertionError:
            print(repr(bedIntervals))
            FacePalm("bedIntervals must be in ParseBed output format!")
        self.IntervalInBed = HTSUtils.IntervalOverlapsBed(
            interval, bedIntervals)
        self.interval = interval
        self.DOR = DOR
        self.bedIntervals = bedIntervals
        self.ID = str(uuid.uuid4().get_hex().upper()[0:8])

    def __str__(self):
        return "\t".join([str(i) for i in [["SegmentID=" + self.ID] +
                                           self.interval + [self.DOR] +
                                           ["InBed={}".format(
                                            self.IntervalInBed)]]])


class PutativeXLoc:

    """
    Contains a list of XLocSegment objects and has a __str__ method which
    produces a line with all regions (most likely only two) involved in the
    rearrangement, along with a randomly generated uuid. This uuid is the
    basename for the bam file containing the supporting reads.
    TODO: Eventually remove the assertions for speed.
    """

    def __init__(self, DORList="default",
                 intervalList="default",
                 ReadPairs="default",
                 bedIntervals="default",
                 header="default",
                 TransType="UnspecifiedSV",
                 inBAM="default"):
        if(inBAM == "default"):
            ThisIsMadness("input BAM path required for SV VCF "
                          "Writing required.")
        self.TransType = TransType
        assert isinstance(header, dict)
        self.segments = [XLocSegment(DOR=dor, bedIntervals=bedIntervals,
                                     interval=interval)
                         for dor, interval in zip(DORList, intervalList)]
        self.ID = self.TransType + str(uuid.uuid4().get_hex().upper()[0:12])
        self.ReadPairs = ReadPairs
        self.intervals = intervalList
        if(DORList == "default"):
            DORList = [0] * len(self.intervals)
        try:
            assert (isinstance(bedIntervals[0], list) and
                    isinstance(bedIntervals[0][0], str) and
                    isinstance(bedIntervals[0][1], int))
        except AssertionError:
            print(repr(bedIntervals))
            FacePalm("bedIntervals should be in ParseBed format!")
        self.bed = bedIntervals
        self.inBAM = inBAM
        self.nsegments = len(self.segments)

    def __str__(self):
        string = ("@PutativeTranslocationID={}\tContig\tStart "
                  "[0-based]\tStop\tMean DOR\n".format(self.ID))
        for segment in self.segments:
            if(isinstance(segment.__str__(), str)):
                string += segment.__str__() + "\n"
        return string

    def WriteReads(self, outBAM="default", header="default"):
        if(outBAM == "default"):
            outBAM = self.ID + ".xloc.bam"
        assert isinstance(header, dict)
        outHandle = pysam.AlignmentFile(outBAM, "wb", header=header)
        for ReadPair in self.ReadPairs:
            HTSUtils.WritePairToHandle(ReadPair, handle=outHandle)


def ClusterByInsertSize(ReadPairs,
                        insDistance="default", minClustSize=3):
    """
    Takes a list of ReadPair objects and return a list of lists of ReadPair
    objects. Each list of ReadPair objects has been clustered by insert size.
    The difference between this function and ClusterByInsertSize is that this
    only expands clusters with the reads outside of the bed file.
    """
    # Check that it's a list of ReadPairs
    assert isinstance(ReadPairs[0], HTSUtils.ReadPair)
    # Assert that these are all mapped to the same contig
    assert len(list(set([pair.read1_contig for pair in ReadPairs]))) == 1
    if(insDistance == "default"):
        insDistance = ReadPairs[0].read1.query_length
        pl("No insert size distance provided - default of "
           " read length set: {}".format(insDistance))
    ClusterList = []
    ReadPairs = sorted(ReadPairs, key=oag("insert_size"))
    workingSet = []
    workingInsertSize = 0
    for pair in ReadPairs:
        if(workingInsertSize == 0):
            workingInsertSize = pair.insert_size
            workingSet.append(pair)
            continue
        if(pair.insert_size - workingInsertSize <= insDistance):
            workingSet.append(pair)
            workingInsertSize = pair.insert_size
        else:
            # print("Next ReadPair has a very different insert size.")
            if(len(workingSet) < 2):
                workingSet = []
                workingInsertSize = 0
                continue
            ClusterList.append(workingSet)
            workingInsertSize = 0
            workingSet = []
    if(len(workingSet) != 0):
        ClusterList.append(workingSet)
    return [i for i in ClusterList if len(i) >= minClustSize]


def SVSupportingReadPairs(bedInterval, recList="default", inHandle="default",
                          dist="default", minMQ=20, SVType="default"):
    """
    Takes a bedInterval (chrom [str], start [int], stop [int],
    0-based, closed-end notation) and a list of records. (All
    SV-relevant BAM records is standard.)
    """
    if isinstance(dist, str):
        dist = recList[0].query_length
    assert (isinstance(bedInterval[0], str) and
            isinstance(bedInterval[1], int))
    assert isinstance(inHandle, pysam.calignmentfile.AlignmentFile)
    try:
        assert isinstance(recList[0], pysam.calignmentfile.AlignedSegment)
    except AssertionError:
        ThisIsMadness("recList must be a list of AlignedSegment objects")
    ReadOutBedList = [rec for rec in recList if
                      HTSUtils.ReadWithinDistOfBedInterval(rec,
                                                           bedLine=bedInterval,
                                                           dist=dist) and
                      rec.mapq >= minMQ]
    ReadMateInBed = []
    for read in ReadOutBedList:
        try:
            ReadMateInBed.append(inHandle.mate(read))
        except ValueError:
            # pl("Read mate not included, as it is unmapped.")
            pass
    ReadPairs = []
    for out, inside in zip(ReadOutBedList, ReadMateInBed):
        if(out.is_read1):
            ReadPairs.append(HTSUtils.ReadPair(out, inside))
        else:
            ReadPairs.append(HTSUtils.ReadPair(inside, out))
    # Changed the list of read pairs to a list of sets of readpairs, in
    # case both reads are out of the bed region, so as to not artificially
    # inflate the number of supporting read families.
    RPSet = list(set(ReadPairs))
    if(SVType == "default"):
        print("RPSet length: {}".format(len(RPSet)))
        return RPSet
    print("RPSet length before filtering: {}".format(len(RPSet)))
    for tag in SVType.split(','):
        RPSet = [rp for rp in RPSet if tag in rp.SVTags]
    print("RPSet after filtering: {}".format(len(RPSet)))
    return RPSet


# def CallIntraChrom(Interval, ):


def PileupMDC(ReadPairList, minClustDepth=5,
              bedfile="default", minPileupLen=8, bedDist=10000):
    if(isinstance(bedfile, str)):
        bedfile = ParseBed(bedfile)
    assert len(ReadPairList) != 0
    try:
        assert isinstance(ReadPairList[0], HTSUtils.ReadPair)
    except IndexError:
        print(repr(ReadPairList))
        raise ThisIsMadness("Something is wrong!!!")
    contigs = list(set([rp.read1_contig for rp in ReadPairList] +
                       [rp.read2_contig for rp in ReadPairList]))
    PotTransIntervals = []
    for contig in contigs:
        ContigReads = [rp.read1 for rp in ReadPairList if
                       rp.read1_contig == contig] + [rp.read2 for rp in
                                                     ReadPairList if
                                                     rp.read2_contig == contig]
        PosCounts = HTSUtils.ReadListToCovCounter(ContigReads,
                                                  minClustDepth=minClustDepth,
                                                  minPileupLen=minPileupLen)
        # Make a list of coordinates for investigating
        bedIntervalList = HTSUtils.CreateIntervalsFromCounter(
            PosCounts, minPileupLen=minPileupLen,
            contig=contig,
            bedIntervals=bedfile)
        # Grab each region which lies outside of the bed file.
        RegionsToPull = []
        for bedLine in bedIntervalList:
            if(HTSUtils.IntervalOverlapsBed(bedLine, bedIntervals=bedfile,
                                            bedDist=bedDist)
               is False):
                RegionsToPull.append(bedLine)
            else:
                continue
                """
                FacePalm("Something's not working as hoped - regions not"
                         " in bed should have been filtered out already.")
                """
        PotTransIntervals += RegionsToPull
    PotTransIntervals = sorted(PotTransIntervals, key=oig(1))
    MergedPTIs = []
    for pti in PotTransIntervals:
        if("workingPTI" not in locals()):
            workingPTI = copy.copy(pti)
        else:
            if(pti[1] - 1 == workingPTI[2]):
                workingPTI = [pti[0], workingPTI[1], pti[2]]
            else:
                MergedPTIs.append(workingPTI)
                del workingPTI
    return MergedPTIs


def PileupISClustersByPos(ClusterList, minClustDepth=5,
                          bedfile="default", minPileupLen=8, bedDist=0):
    """
    Takes a list of lists of ReadPair objects which have been clustered by
    insert size, creates a list of intervals outside the bed capture region.
    These are then fed to SVSupportingReadPairs.
    bedDist is provided to avoid calling translocations where the reads
    are on the edge of the capture.
    """
    assert len(ClusterList) != 0
    if(isinstance(bedfile, str)):
        bedpath = copy.copy(bedfile)
        bedfile = HTSUtils.ParseBed(bedfile)
        pl("Bedfile parsed! Path: {}".format(bedpath))
        del bedpath
    try:
        assert isinstance(ClusterList[0][0], HTSUtils.ReadPair)
    except IndexError:
        print(repr(ClusterList))
        raise ThisIsMadness("Something is wrong!!!")
    for cluster in ClusterList:
        print("Length of cluster: {}".format(len(cluster)))
    PotTransIntervals = []
    for cluster in ClusterList:
        if(len(cluster) < minClustDepth):
            continue
        PosCounts = HTSUtils.ReadPairListToCovCounter(
            cluster, minClustDepth=minClustDepth, minPileupLen=minPileupLen)
        # print(repr(PosCounts))
        # Make a list of coordinates for investigating
        intervalList = HTSUtils.CreateIntervalsFromCounter(
            PosCounts, minPileupLen=minPileupLen,
            contig=ClusterList[0][0].read1_contig)
        pl("Number of intervals to investigate: {}".format(
            len(intervalList)))
        # Grab each region which lies outside of the bed file.
        intervalList = [line for line in intervalList if
                        HTSUtils.IntervalOverlapsBed(line, bedfile)
                        is False]
        pl("Number of intervals which overlap the bed direct"
           "ly: {}".format(len(intervalList)))
        pl("intervalList repr: {}".format(repr(intervalList)))
        PotTransIntervals += intervalList
    PotTransIntervals = sorted(PotTransIntervals, key=oig(1))
    pl("Number of intervals outside of bed for investigation: {}".format(
        len(PotTransIntervals)))
    pl("PotTransIntervals repr: {}".format(PotTransIntervals))
    return PotTransIntervals
    """
    MergedPTIs = []
    for pti in PotTransIntervals:
        if("workingPTI" not in locals()):
            workingPTI = copy.copy(pti)
            MergedPTIs.append(workingPTI)
        else:
            if(pti[1] - 1 == workingPTI[2]):
                workingPTI = [pti[0], workingPTI[1], pti[2]]
            else:
                MergedPTIs.append(workingPTI)
                del workingPTI
    return MergedPTIs
    """


class TranslocationVCFLine:
    """
    Contains all the information required for writing a line in a VCF file for
    a translocation.
    """

    def __init__(self, PutativeXLocObj, ref="default", inBAM="default",
                 TransType="UnspecifiedSV"):
        assert isinstance(PutativeXLocObj, PutativeXLoc)
        self.TransType = TransType
        if(ref == "default"):
            raise ThisIsMadness("Reference must be provided for "
                                "creating a VCFLine.")
        if(isinstance(inBAM, str)):
            inBAM = pysam.AlignmentFile(inBAM, "rb")
        elif(isinstance(inBAM, pysam.calignmentfile.AlignmentFile) is False):
            raise ThisIsMadness("A source BAM file required for VCFLine.")
        segmentsInBed = [segment for segment in PutativeXLocObj.segments if
                         HTSUtils.IntervalOverlapsBed(segment.interval,
                                                      segment.bedIntervals)]
        segmentLengths = [segment.interval[2] - segment.interval[1] for segment
                          in PutativeXLocObj.segments]
        segmentLengthsInBed = [segment.interval[2] - segment.interval[1] for
                               segment in segmentsInBed]
        if(len(segmentsInBed) == 0):
            self.VCFRecSegment = PutativeXLocObj.segments[
                nargmax(segmentLengths)]
        else:
            self.VCFRecSegment = segmentsInBed[nargmax(segmentLengthsInBed)]
        self.partnerSegments = [segment for segment in
                                PutativeXLocObj.segments if
                                segment != self.VCFRecSegment]
        self.NumPartners = len(self.partnerSegments)
        self.CHROM = self.VCFRecSegment.interval[0]
        self.POS = self.VCFRecSegment.interval[1] + 1
        self.REF = "N"
        self.ALT = "<TRA>"
        self.QUAL = "QUALITY_IN_PROGRESS"
        self.ID = PutativeXLocObj.ID
        self.FILTER = "FILTER_IN_PROGRESS"
        # Number Merged Family Pairs supporting Structural Variant
        # Number Total Read Pairs Supporting Structural Variant
        StartsAndEnds = []
        for readpair in PutativeXLocObj.ReadPairs:
            StartsAndEnds += [readpair.read1.reference_start,
                              readpair.read2.reference_start,
                              readpair.read1.reference_end,
                              readpair.read1.reference_end]
        self.TDIST = sorted(StartsAndEnds)[-1] - sorted(StartsAndEnds)[0]
        self.InfoFields = {"NMFPSSV": len(PutativeXLocObj.ReadPairs),
                           "TYPE": "TRA",
                           "NTRPSSV": sum([int(pair.read1.opt("FM")) for pair
                                           in PutativeXLocObj.ReadPairs]),
                           "TDIST": self.TDIST}
        self.InfoFields["SVSEGS"] = ""
        for seg in self.partnerSegments:
            self.InfoFields["SVSEGS"] = "|".join(
                [str(i) for i in
                 [seg.interval[0], seg.interval[1],
                  seg.interval[2], seg.DOR]]) + ":"
        self.FormatFields = {}
        self.InfoStr = ";".join(
            ["=".join([key, str(self.InfoFields[key])])
             for key in sorted(self.InfoFields.iterkeys())])
        if(len(self.FormatFields.keys()) == 0):
            self.FormatStr = "\t"
        else:
            self.FormatStr = (
                ":".join(sorted(self.FormatFields.iterkeys())) +
                "\t" + ":".join(str(
                    self.FormatFields[key]) for key in sorted(
                        self.FormatFields.iterkeys())))
        self.str = "\t".join([str(i) for i in [self.CHROM,
                                               self.POS,
                                               self.ID,
                                               self.REF,
                                               self.ALT,
                                               self.QUAL,
                                               self.FILTER,
                                               self.InfoStr,
                                               self.FormatStr]])

    def update(self):
        self.FormatKey = ":".join(sorted(self.FormatFields.iterkeys()))
        self.FormatValue = ":".join([str(self.FormatFields[key])
                                     for key in
                                     sorted(self.FormatFields.iterkeys())])
        self.FormatStr = (":".join(sorted(self.FormatFields.iterkeys())) +
                          "\t" +
                          ":".join(
                              str(self.FormatFields[key])
                              for key in
                              sorted(self.FormatFields.iterkeys())))
        self.InfoStr = ";".join([key + "=" + str(self.InfoFields[key])
                                 for key in
                                 sorted(self.InfoFields.iterkeys())])

    def __str__(self):
        self.update()
        self.str = "\t".join([str(i) for i in [self.CHROM,
                                               self.POS,
                                               self.ID,
                                               self.REF,
                                               self.ALT,
                                               self.QUAL,
                                               self.FILTER,
                                               self.InfoStr,
                                               self.FormatStr]])
        return self.str


def returnDefault():
    """
    Simply returns default, facilitating the default convention
    of BMFTools being applied to this default dictionary.
    """
    return "default"

SVParamDict = defaultdict(returnDefault)
SVParamDict['LI'] = 10000
SVParamDict['MI'] = [500, 100000]
SVParamDict['DRP'] = 0.5

#  Made a dictionary for all structural variant candidate types
#  such that cycling through the list will be easier.
#  Extra field provided for each.


class SVTagFn(object):
    """
    Base class for SV tag testers.
    """
    def __init__(self, func=FacePalm, extraField="default",
                 tag="default"):
        self.extraField = extraField
        self.func = func
        if(func == FacePalm):
            FacePalm("func must be set for SVTag condition!")
        if(tag == "default"):
            raise FacePalm("tag must be set for SVTagTest!")
        self.tag = tag

    def test(self, pysam.calignmentfile.AlignedSegment read1,
             pysam.calignmentfile.AlignedSegment read2,
             extraField="default"):
        if(extraField != "default"):
            if self.func(read1, read2, extraField=extraField):
                try:
                    SVTag = read1.opt("SV")
                    read1.set_tag("SV", SVTag + "," + self.tag, "Z")
                    read2.set_tag("SV", SVTag + "," + self.tag, "Z")
                except KeyError:
                    read1.set_tag("SV", self.tag, "Z")
                    read2.set_tag("SV", self.tag, "Z")
        else:
            if self.func(read1, read2, extraField=self.extraField):
                try:
                    SVTag = read1.opt("SV")
                    read1.set_tag("SV", SVTag + "," + self.tag, "Z")
                    read2.set_tag("SV", SVTag + "," + self.tag, "Z")
                except KeyError:
                    read1.set_tag("SV", self.tag, "Z")
                    read2.set_tag("SV", self.tag, "Z")
        return read1, read2

    def __call__(self, *args, **kwargs):
        return self.test(*args, **kwargs)


@cython.returns(cython.bint)
def DRP_SNV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                          pysam.calignmentfile.AlignedSegment read2,
                          extraField=SVParamDict['DRP']):
    """
    Duplex Read Pair
    Whether or not a read pair shares some minimum fraction of aligned
    positions.
    """
    if(extraField != "default"):
        return ReadPairIsDuplex(ReadPair(read1, read2), minShare=extraField)
    else:
        return ReadPairIsDuplex(ReadPair(read1, read2))
SNVTestDict = {}
SNVTestDict['DRP'] = DRP_SNV_Tag_Condition
SVTestList = [SVTagFn(func=DRP_SNV_Tag_Condition, extraField=100000,
                      tag="DRP")]


@cython.returns(cython.bint)
def LI_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                        pysam.calignmentfile.AlignedSegment read2,
                        cython.long extraField=100000):
    maxInsert = extraField
    return abs(read1.tlen) >= maxInsert


SVTestList.append(SVTagFn(func=LI_SV_Tag_Condition, extraField=100000,
                          tag="LI"))
SVTestDict = {"LI": LI_SV_Tag_Condition}


@cython.returns(cython.bint)
def MDC_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    return (read1.reference_id != read2.reference_id)

SVTestDict['MDC'] = MDC_SV_Tag_Condition
SVTestList.append(SVTagFn(func=MDC_SV_Tag_Condition, tag="MDC"))


@cython.returns(cython.bint)
def ORU_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    return (sum([read1.is_unmapped, read2.is_unmapped]) == 1)

SVTestDict['ORU'] = ORU_SV_Tag_Condition
SVTestList.append(SVTagFn(func=ORU_SV_Tag_Condition, tag="ORU"))


@cython.returns(cython.bint)
def MSS_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    if(read1.reference_id == read2.reference_id):
        return ((sum([read1.is_reverse, read2.is_reverse]) != 1 and
                 read1.reference_id == read2.reference_id))
    else:
        return False

SVTestDict['MSS'] = MSS_SV_Tag_Condition
SVTestList.append(SVTagFn(func=MSS_SV_Tag_Condition, tag="MSS"))


@cython.returns(cython.bint)
def ORB_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    """
    Returns true iff precisely one read is in the bed file region.
    """
    bedRef = extraField
    if(bedRef == "default"):
        raise ThisIsMadness("bedRef must be provded to run this test!")
    return not (sum([RIB(read1, bedRef=bedRef),
                     RIB(read2, bedRef=bedRef)]) - 1)

SVTestDict['ORB'] = ORB_SV_Tag_Condition
SVTestList.append(SVTagFn(func=ORB_SV_Tag_Condition, tag="ORB"))


@cython.returns(cython.bint)
def ORS_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    """
    Returns true iff precisely one read is soft-clipped and the reads are
    considered properly mapped.
    """
    return read1.is_proper_pair and not (sum([is_read_softclipped(read1),
                                              is_read_softclipped(read2)]) - 1)

"""
SVTestDict['ORS'] = ORS_SV_Tag_Condition
SVTestList.append(SVTagFn(func=ORS_SV_Tag_Condition, tag="ORS"))
I kind of hate the ORS tag. Getting rid of it for now!
"""


@cython.returns(cython.bint)
def MI_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                        pysam.calignmentfile.AlignedSegment read2,
                        extraField=SVParamDict['MI']):
    """
    Returns true if TLEN >= minimum length && TLEN =< LI requirements.
    (Defaults to 500 and 100000)
    Hoping to have it help with bigger indels.
    """
    return (abs(read1.tlen) >= extraField[0] and
            abs(read1.tlen) <= extraField[1])

SVTestList.append(SVTagFn(func=MI_SV_Tag_Condition, tag="MI",
                          extraField=SVParamDict["MI"]))

SNVParamDict = defaultdict(returnDefault)


@cython.returns(cython.bint)
def DSD_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    """
    Duplex Shared Deletion - if read1 and read2 share a deletion
    at the same genomic coordinates.
    """
    try:
        if("DRP" not in read1.opt("SV")):
            return False
    except KeyError:
        pass  # Don't sweat it.
    if(read1.cigarstring is None or read2.cigarstring is None or
       read1.reference_id != read2.reference_id):
        return False
    if("D" in read1.cigarstring and "D" in read2.cigarstring and
       GetDeletedCoordinates(read1) == GetDeletedCoordinates(read2)):
        return True
    return False

SVTestList.append(SVTagFn(func=DSD_SV_Tag_Condition, tag="DSD"))


@cython.returns(cython.bint)
def DSI_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    """
    Duplex Shared Insertion - if read1 and read2 share an insertion
    at the same genomic coordinates.
    """
    cdef list read1list, read2list
    cdef tuple tup
    try:
        if("DRP" not in read1.opt("SV")):
            return False
    except KeyError:
        pass  # Don't sweat it.
    if(read1.cigarstring is None or read2.cigarstring is None):
        return False
    if("I" not in read1.cigarstring or "I" not in read2.cigarstring):
        return False
    if(sum([read1.is_reverse, read2.is_reverse]) != 1):
        return False  # Reads aligned to same strand. Not a good sign.
    read1list = GetInsertedStrs(read1)
    read2list = GetInsertedStrs(read2)
    for tup in read1list:
        if tup in read2list:
            return True
    return False

@cython.returns(cython.bint)
def DDI_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extraField="default"):
    """
    Duplex Discordant Insertion - if one read has an insertion that the
    other read doesn't, even if the other read covers the same region of
    the genome. This assumes that indels have already been left-aligned.
    """
    cdef list read1list, read2list
    cdef cython.bint NoneCigar1, NoneCigar2, iInCigar1, iInCigar2
    if("DRP" not in read1.opt("SV")):
        return False  # Reads gotta overlap pretty far for this to work.
    if(sum([read1.is_reverse, read2.is_reverse]) != 1):
        return False  # Reads aligned to same strand. Not informative...
    NoneCigar1 = (read1.cigarstring is None)
    NoneCigar2 = (read2.cigarstring is None)
    iInCigar1 = ("I" in read1.cigarstring)
    iInCigar2 = ("I" in read2.cigarstring)
    if(NoneCigar1):
        if(NoneCigar2):
            return False
        if(iInCigar2):
            return True
        return False
    if(NoneCigar2):
        if(NoneCigar1):
            return False
        if(iInCigar1):
            return True
        return False
    if(iInCigar1):
        if(not iInCigar2):
            return False
        read1list = GetInsertedStrs(read1)
        read2list = GetInsertedStrs(read2)
        for tup in read1list:
            if tup not in read2list:
                return True
        for tup in read2list:
            if tup not in read1list:
                return True
    return False


@cython.returns(cython.bint)
def DDD_SV_Tag_Condition(pysam.calignmentfile.AlignedSegment read1,
                         pysam.calignmentfile.AlignedSegment read2,
                         extrField="default"):
    return False

SVTestList.append(SVTagFn(func=DSI_SV_Tag_Condition, tag="DSI"))

SVTestDict = cytoolz.merge([SVTestDict, SNVTestDict])
SVParamDict = defaultdict(returnDefault,
                          oadd(SVParamDict.items(),
                               SNVParamDict.items()))


@cython.locals(SVR=cython.bint, maxInsert=cython.long)
@cython.returns(tuple)
def MarkSVTags(pysam.calignmentfile.AlignedSegment read1,
               pysam.calignmentfile.AlignedSegment read2,
               bedObj="default", maxInsert=100000,
               testDict=SVTestDict, paramDict=SVParamDict):
    """
    Marks all SV tags on a pair of reads.
    """
    from utilBMF.HTSUtils import ParseBed
    if bedObj == "default":
        raise ThisIsMadness("Bed file required for marking SV tags.")
    SVParamDict['ORB'] = bedObj
    SVParamDict['LI'] = maxInsert
    FeatureList = sorted([i for i in SVTestDict.iterkeys()])
    SVR = False
    assert read1.query_name == read2.query_name
    # print("SVParamDict: {}".format(repr(SVParamDict)))
    # print("SVTestDict: {}".format(repr(SVTestDict)))
    for key in FeatureList:
        if(SVTestDict[key](read1, read2, extraField=SVParamDict[key])):
            SVR = True
            try:
                read1.setTag("SV", read1.opt("SV") + "," + key)
                read2.setTag("SV", read2.opt("SV") + "," + key)
                if("NF" in read1.opt("SV").split(",")):
                    read1.setTag(
                        "SV", ','.join([
                            i for i in read1.opt(
                                "SV").split(
                                    ",") if i != "NF"]))
                if("NF" in read2.opt("SV").split(",")):
                    read2.setTag(
                        "SV", ','.join([
                            i for i in read2.opt(
                                "SV").split(
                                    ",") if i != "NF"]))
            except KeyError:
                read1.setTag("SV", key)
                read2.setTag("SV", key)
    if SVR is False:
        read1.setTag("SV", "NF")
        read2.setTag("SV", "NF")
    return read1, read2


@cython.returns(tuple)
def MarkSVTagsFn(pysam.calignmentfile.AlignedSegment read1,
                 pysam.calignmentfile.AlignedSegment read2,
                 bedObj="default", cython.long maxInsert=100000,
                 list testList=SVTestList,
                 paramDict=SVParamDict):
    """
    Marks all SV tags on a pair of reads.
    """
    cdef list SVPKeys
    cdef cython.bint SVR
    if bedObj == "default":
        raise ThisIsMadness("Bed file required for marking SV tags.")
    SVParamDict['ORB'] = bedObj
    SVParamDict['LI'] = maxInsert
    SVPKeys = SVParamDict.keys()
    SVR = False
    assert read1.query_name == read2.query_name
    # print("SVParamDict: {}".format(repr(SVParamDict)))
    # print("SVTestDict: {}".format(repr(SVTestDict)))
    for test in testList:
        if(test.tag in SVPKeys):
            read1, read2 = test(read1, read2,
                                extraField=SVParamDict[test.tag])
        else:
            read1, read2 = test(read1, read2)
    try:
        read1.opt("SV")
    except KeyError:
        read1.setTag("SV", "NF")
        read2.setTag("SV", "NF")
    return read1, read2


def GetSVRelevantRecordsPaired(inBAM, SVBam="default",
                               bedfile="default",
                               supplementary="default",
                               cython.long maxInsert=100000,
                               tempBAMPrefix="default",
                               FullBam="default",
                               summary="default"):
    """
    Requires a name-sorted, paired-end bam file where pairs have been kept
    together. (If a read is to be removed, its mate must also be removed.)
    Optionally, a supplementary bam file can be provided for additional
    information.
    Additionally, adds tags for different characteristics relevant
    to structural variants.
    If tempBAMPrefix is set, then reads relevant to each feature will be
    written to BAM files labeled accordingly.
    "SV" is the tag. It can hold multiple values, separated by commas.
    LI for Large Insert
    MDC for Mapped to Different Contig
    ORU for One Read Unmapped
    MSS for Mapped to Same Strand
    ORB for One Read In Bed Region
    (Spanning Bed with Improper pair)
    NF for None Found
    """
    cdef pysam.calignmentfile.AlignedSegment read
    cdef pysam.calignmentfile.AlignedSegment read1
    cdef pysam.calignmentfile.AlignedSegment read2
    if(SVBam == "default"):
        SVBam = '.'.join(inBAM.split('.')[0:-1]) + '.sv.bam'
    if(FullBam == "default"):
        FullBam = '.'.join(inBAM.split('.')[0:-1]) + '.SVmarked.bam'
    from utilBMF.HTSUtils import ParseBed
    bed = ParseBed(bedfile)
    SVParamDict['ORB'] = bed
    SVParamDict['LI'] = maxInsert
    SVCountDict = {key: 0 for key in SVTestDict.iterkeys()}
    SVCountDict['NOSVR'] = 0  # "No Structural Variant Relevance"
    SVCountDict['SVR'] = 0  # "Structural Variant-Relevant"
    inHandle = pysam.AlignmentFile(inBAM, "rb")
    FullOutHandle = pysam.AlignmentFile(FullBam, "wb", template=inHandle)
    fhw = FullOutHandle.write
    for read in inHandle:
        WritePair = False
        if(read.is_read1):
            read1 = read
            continue
        if(read.is_read2):
            read2 = read
        assert read1.query_name == read2.query_name
        read1, read2 = MarkSVTagsFn(read1, read2, bedObj=bed)
        fhw(read1)
        fhw(read2)
    inHandle.close()
    FullOutHandle.close()
    SVCountDict["TOTAL"] = SVCountDict["SVR"] + SVCountDict["NOSVR"]
    for key in SVCountDict.iterkeys():
        pl("Number of reads marked with key {}: {}".format(
            key, SVCountDict[key]))
    if(summary != "default"):
        writeSum = open(summary, "w")
        writeSum.write("#Category\tCount\tFraction\n")
        for key in SVCountDict.iterkeys():
            if(SVCountDict['TOTAL'] == 0):
                pl("No reads marked with SV tag - something has gone wrong.")
                pl("WARNING!!!!!! SV analysis failed!")
                return SVBam, FullBam
            writeSum.write(
                "{}\t{}\t{}\n".format(key,
                                      SVCountDict[key],
                                      SVCountDict[key] / float(
                                          SVCountDict['TOTAL'])))
        writeSum.close()
    return SVBam, FullBam


def MakeConsensus(seqs):
    assert isinstance(seqs, list)
    assert isinstance(seqs[0], str)
    pass


def BkptSequenceInterReads(list reads):
    """
    Not written yet.
    """
    cdef pysam.calignmentfile.AlignedSegment read
    raise ThisIsMadness("Unfinished function.")
    newSeq = ""
    try:
        assert len(set([read.reference_id for read in reads if
                        read.is_unmapped is False])) == 2
    except AssertionError:
        FacePalm("Interchromosomal translocations should be between 2"
                 "contigs.")
    return newSeq


@cython.returns(tuple)
def SplitSCReadSet(reads):
    cdef pysam.calignmentfile.AlignedSegment read
    scReads = []
    clippedSeqs = []
    for read in reads:
        SCSplitReads = SplitSCRead(read)
        scReads.append(SCSplitReads[0])
        clippedSeqs += SCSplitReads[1]
    return scReads, clippedSeqs


@cython.locals(Success=cython.bint)
def BkptSequenceIntraReads(reads):
    """
    Attempts to create a consensus sequence out of the reads for
    reads with large inserts.
    """
    # reads, clippedSeqs = SplitSCReadSet(reads)

    cdef pysam.calignmentfile.AlignedSegment read
    Success = False
    newSeq = ""
    try:
        assert isinstance(reads[0], pysam.calignmentfile.AlignedSegment)
    except AssertionError:
        FacePalm("BkptSequenceIntraReads requires a list of "
                 "pysam AlignedSegment objects as input!")
    try:
        assert len(set([read.reference_id for read in reads if
                        read.is_unmapped is False])) == 1
    except AssertionError:
        FacePalm("Intrachromosomal translocations should all be"
                 "on the same contig.")
    # Separate reads based on which end of the translocation they're part of.
    negReads = sorted([read for read in reads if read.tlen < 0],
                      key=oag("pos"))
    posReads = sorted([read for read in reads
                      if read.tlen > 0], key=oag("pos"))
    negSeqs = [read.seq if read.is_reverse else
               Seq(read.seq).reverse_complement().seq for read in negReads]
    posSeqs = [read.seq if read.is_reverse else
               Seq(read.seq).reverse_complement().seq for read in posReads]
    negConsensus = MakeConsensus(negSeqs)
    posConsensus = MakeConsensus(posSeqs)
    return newSeq, Success


def BkptSequenceIntraRP(ReadPairs):
    """
    Calls converts a list of read pairs to a list of reads and
    calls BkptSequenceIntraReads
    """
    return BkptSequenceIntraReads(list(cfi([i.getReads() for i in
                                            ReadPairs])))


def BkptSequenceInterRP(ReadPairs):
    """
    Calls converts a list of read pairs to a list of reads and
    calls BkptSequenceInterReads
    """
    return BkptSequenceInterReads(list(cfi([i.getReads() for i in
                                            ReadPairs])))


def BkptSequenceFromRPSet(ReadPairs, intra=True):
    try:
        assert isinstance(ReadPairs[0], HTSUtils.ReadPair)
    except AssertionError:
        FacePalm("Input for Breakpoint sequence construction must be a "
                 "list of ReadPair objects!")
    if(intra):
        return BkptSequenceIntraRP(ReadPairs)
    elif(intra is False):
        return BkptSequenceInterRP(ReadPairs)
