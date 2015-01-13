from MawCluster.SNVUtils import *
import pysam

"""
Programs which write VCFs.
Currently: SNVCrawler.

In development: SV
"""


def SNVCrawler(inBAM,
               bed="default",
               minMQ=0,
               minBQ=0,
               OutVCF="default",
               MaxPValue=1e-15,
               keepConsensus=False,
               reference="default",
               reference_is_path=False,
               commandStr="default",
               fileFormat="default",
               FILTERTags="default",
               INFOTags="default",
               FORMATTags="default",
               writeHeader=True):
    pl("Command to reproduce function call: "
       "SNVCrawler({}, bed=\"{}\"".format(inBAM, bed) +
       ", minMQ={}, minBQ={}, OutVCF".format(minMQ, minBQ) +
       "=\"{}\", MaxPValue={}".format(OutVCF, MaxPValue) +
       ",keepConsensus={}, reference=".format(keepConsensus) +
       "\"{}\", reference_is_path={}".format(reference, reference_is_path) +
       "commandStr=\"{}\", fileFormat=\"{}\"".format(commandStr, fileFormat) +
       ", FILTERTags=\"{}\", INFOTags=\"{}\"".format(FILTERTags, INFOTags) +
       ", FORMATTags=\"{}\")".format(FORMATTags))
    if(isinstance(bed, str) and bed != "default"):
        bed = HTSUtils.ParseBed(bed)
    if(OutVCF == "default"):
        OutVCF = inBAM[0:-4] + ".bmf.vcf"
    inHandle = pysam.AlignmentFile(inBAM, "rb")
    outHandle = open(OutVCF, "w+")
    if(writeHeader is True):
        outHandle.write(GetVCFHeader(fileFormat=fileFormat,
                                     FILTERTags=FILTERTags,
                                     commandStr=commandStr,
                                     reference=reference,
                                     reference_is_path=False,
                                     header=inHandle.header,
                                     INFOTags=INFOTags,
                                     FORMATTags=FORMATTags))

    if(bed != "default"):
        for line in bed:
            puIterator = inHandle.pileup(line[0], line[1],
                                         max_depth=30000,
                                         multiple_iterators=True)
            while True:
                try:
                    PileupColumn = puIterator.next()
                    PC = PCInfo(PileupColumn, minMQ=minMQ, minBQ=minBQ)
                except ValueError:
                    pl(("Pysam sometimes runs into errors during iteration w"
                        "hich are not handled with any elegance. Continuing!"))
                    continue
                except StopIteration:
                    pl("Finished iterations.")
                    break
                if(line[2] <= PC.pos):
                    break
                VCFLineString = VCFPos(PC, MaxPValue=MaxPValue,
                                       keepConsensus=keepConsensus,
                                       reference=reference
                                       ).ToString()
                if(len(VCFLineString) != 0):
                    outHandle.write(VCFLineString + "\n")
    else:
        puIterator = inHandle.pileup(max_depth=30000)
        while True:
            try:
                PC = PCInfo(puIterator.next(), minMQ=minMQ, minBQ=minBQ)
            except ValueError:
                pl(("Pysam sometimes runs into errors during iteration which"
                    " are not handled with any elegance. Continuing!"))
                continue
            except StopIteration:
                break
            # TODO: Check to see if it speeds up to not assign and only write.
            VCFLineString = VCFPos(PC, MaxPValue=MaxPValue,
                                   keepConsensus=keepConsensus,
                                   reference=reference).ToString()
            if(len(VCFLineString) != 0):
                outHandle.write(VCFLineString + "\n")
    return OutVCF


# Trying to "parallelize" this...
# I'll get around to it later.
"""


def SNVMinion(inBAM,
              bed="default",
              minMQ=0,
              minBQ=0,
              VCFLines="default",
              MaxPValue=1e-15,
              keepConsensus=False,
              reference="default",
              reference_is_path=False,
              commandStr="default",
              fileFormat="default",
              FILTERTags="default",
              INFOTags="default",
              FORMATTags="default"):
    if(isinstance(bed, str) and bed != "default"):
        bed = HTSUtils.ParseBed(bed)
    if(VCFLines == "default"):
        VCFLines = inBAM[0:-4] + ".bmf.vcf"
    inHandle = pysam.AlignmentFile(inBAM, "rb")
    outHandle = open(VCFLines, "w+")
    if(bed != "default"):
        for line in bed:
            puIterator = inHandle.pileup(line[0], line[1],
                                         max_depth=30000,
                                         multiple_iterators=True)
            while True:
                try:
                    PileupColumn = puIterator.next()
                    PC = PCInfo(PileupColumn, minMQ=minMQ, minBQ=minBQ)
                    # print(PC.toString())
                except ValueError:
                    pl(("Pysam sometimes runs into errors during iteration w"
                        "hich are not handled with any elegance. Continuing!"))
                    continue
                except StopIteration:
                    pl("Finished iterations.")
                    break
                if(line[2] <= PC.pos):
                    break
                VCFLineString = VCFPos(PC, MaxPValue=MaxPValue,
                                       keepConsensus=keepConsensus,
                                       reference=reference
                                       ).ToString()
                if(len(VCFLineString) != 0):
                    outHandle.write(VCFLineString + "\n")
    else:
        puIterator = inHandle.pileup(max_depth=30000)
        while True:
            try:
                PC = PCInfo(puIterator.next(), minMQ=minMQ, minBQ=minBQ)
            except ValueError:
                pl(("Pysam sometimes runs into errors during iteration which"
                    " are not handled with any elegance. Continuing!"))
                continue
            except StopIteration:
                break
            # TODO: Check to see if it speeds up to not assign and only write.
            VCFLineString = VCFPos(PC, MaxPValue=MaxPValue,
                                   keepConsensus=keepConsensus,
                                   reference=reference).ToString()
            if(len(VCFLineString) != 0):
                outHandle.write(VCFLineString + "\n")
    return VCFLines


def CallSNVCrawler():
    pass


def SNVMaster(inBAM,
              bed="default",
              minMQ=0,
              minBQ=0,
              VCFLines="default",
              MaxPValue=1e-15,
              keepConsensus=False,
              reference="default",
              reference_is_path=False,
              commandStr="default",
              fileFormat="default",
              FILTERTags="default",
              INFOTags="default",
              FORMATTags="default",
              ByContig=True,
              children=2):
    from subprocess import Popen
    if(isinstance(bed, str) and bed != "default"):
        bed = HTSUtils.ParseBed(bed)
    if(VCFLines == "default"):
        VCFLines = inBAM[0:-4] + ".bmf.vcf"
    inHandle = pysam.AlignmentFile(inBAM, "rb")
    outHandle = open(VCFLines, "w")
    outHandle.write(GetVCFHeader(fileFormat=fileFormat,
                                 FILTERTags=FILTERTags,
                                 commandStr=commandStr,
                                 reference=reference,
                                 reference_is_path=False,
                                 header=inHandle.header,
                                 INFOTags=INFOTags,
                                 FORMATTags=FORMATTags))
    if(ByContig is True):
        contigList = list(set([line[0] for line in bed]))
        jobList = []
        for thread in range(int(children)):
            jobList.append(CallSNVCrawler(inBAM,
                           bed="default",
                           minMQ=0,
                           minBQ=0,
                           VCFLines="default",
                           MaxPValue=1e-15,
                           keepConsensus=False,
                           reference="default",
                           reference_is_path=False,
                           commandStr="default",
                           fileFormat="default",
                           FILTERTags="default",
                           INFOTags="default",
                           FORMATTags="default"))
    pass
"""