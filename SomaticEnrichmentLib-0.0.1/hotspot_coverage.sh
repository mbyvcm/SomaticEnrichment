#!/bin/bash
set -euo pipefail

# Christopher Medway AWMGS
# Performs all the coverage calculation across the panel and hotspot regions

seqId=$1
sampleId=$2
panel=$3
pipelineName=$4
pipelineVersion=$5
minimumCoverage=$6
vendorCaptureBed=$7
padding=$8
minBQS=$9
minMQS=${10}
gatk3=${11}

# add given padding to vendor bedfile
/share/apps/bedtools-distros/bedtools-2.26.0/bin/bedtools \
    slop \
    -i $vendorCaptureBed \
    -b $padding \
    -g /share/apps/bedtools-distros/bedtools-2.26.0/genomes/human.hg19.genome > vendorCaptureBed_100pad.bed

# generate per-base coverage: variant detection sensitivity
/share/apps/jre-distros/jre1.8.0_131/bin/java -XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Djava.io.tmpdir=/state/partition1/tmpdir -Xmx4g -jar $gatk3 \
    -T DepthOfCoverage \
    -R /state/partition1/db/human/gatk/2.8/b37/human_g1k_v37.fasta \
    -I /data/results/$seqId/$panel/$sampleId/"$seqId"_"$sampleId".bam \
    -L vendorCaptureBed_100pad.bed \
    -o /data/results/$seqId/$panel/$sampleId/"$seqId"_"$sampleId"_DepthOfCoverage \
    --countType COUNT_FRAGMENTS \
    --minMappingQuality $minMQS \
    --minBaseQuality $minBQS \
    -ct $minimumCoverage \
    --omitLocusTable \
    -rf MappingQualityUnavailable \
    -dt NONE

# reformat depth file
sed 's/:/\t/g' /data/results/$seqId/$panel/$sampleId/"$seqId"_"$sampleId"_DepthOfCoverage \
    | grep -v "^Locus" \
    | sort -k1,1 -k2,2n \
    | /share/apps/htslib-distros/htslib-1.4.1/bgzip > /data/results/$seqId/$panel/$sampleId/"$seqId"_"$sampleId"_DepthOfCoverage.gz

# tabix index depth file
/share/apps/htslib-distros/htslib-1.4.1/tabix -b 2 -e 2 -s 1 /data/results/$seqId/$panel/$sampleId/"$seqId"_"$sampleId"_DepthOfCoverage.gz

# loop over referral bedfiles and generate coverage report 
if [ -d /data/diagnostics/pipelines/$pipelineName/$pipelineName-$pipelineVersion/$panel/hotspot_coverage ];then

    mkdir -p /data/results/$seqId/$panel/$sampleId/hotspot_coverage

    source /home/transfer/miniconda3/bin/activate CoverageCalculatorPy

    for bedFile in /data/diagnostics/pipelines/"$pipelineName"/"$pipelineName"-"$pipelineVersion"/$panel/hotspot_coverage/*.bed; do

        name=$(echo $(basename $bedFile) | cut -d"." -f1)
        echo $name

        python /home/transfer/pipelines/CoverageCalculatorPy/CoverageCalculatorPy.py \
            -B $bedFile \
            -D /data/results/$seqId/$panel/$sampleId/"$seqId"_"$sampleId"_DepthOfCoverage.gz \
            --depth $minimumCoverage \
            --padding 0 \
            --groupfile /data/diagnostics/pipelines/$pipelineName/$pipelineName-$pipelineVersion/$panel/hotspot_coverage/"$name".groups \
            --outname "$sampleId"_"$name" \
            --outdir /data/results/$seqId/$panel/$sampleId/hotspot_coverage/

        # remove header from gaps file
        if [[ $(wc -l < /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_"$name".gaps) -eq 1 ]]; then
            
            # no gaps
            touch /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_"$name".nohead.gaps
        else
            # gaps
            grep -v '^#' /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_"$name".gaps > /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_"$name".nohead.gaps
        fi

        rm /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_"$name".gaps

    done

    source /home/transfer/miniconda3/bin/deactivate


    # add hgvs nomenclature to gaps
    source /home/transfer/miniconda3/bin/activate bed2hgvs

    for gapsFile in /data/results/$seqId/$panel/$sampleId/hotspot_coverage/*genescreen.nohead.gaps /data/results/$seqId/$panel/$sampleId/hotspot_coverage/*hotspots.nohead.gaps; do

        name=$(echo $(basename $gapsFile) | cut -d"." -f1)
        echo $name

        python /data/diagnostics/apps/bed2hgvs/bed2hgvs-0.1.1/bed2hgvs.py \
           --config /data/diagnostics/apps/bed2hgvs/bed2hgvs-0.1/configs/cluster.yaml \
            --input $gapsFile \
            --output /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$name".gaps \
            --transcript_map /data/diagnostics/pipelines/SomaticEnrichment/SomaticEnrichment-0.0.1/RochePanCancer/RochePanCancer_PreferredTranscripts.txt

        rm /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$name".nohead.gaps
        # mv /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$name".hgvs.gaps /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$name".gaps
    done
    
    source /home/transfer/miniconda3/bin/deactivate

    # combine all total coverage files
    if [ -f /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_coverage.txt ]; then rm /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_coverage.txt; fi
    cat /data/results/$seqId/$panel/$sampleId/hotspot_coverage/*.totalCoverage | grep "FEATURE" | head -n 1 >> /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_coverage.txt
    cat /data/results/$seqId/$panel/$sampleId/hotspot_coverage/*.totalCoverage | grep -v "FEATURE" | grep -vP "combined_\\S+_GENE" >> /data/results/$seqId/$panel/$sampleId/hotspot_coverage/"$sampleId"_coverage.txt
    rm /data/results/$seqId/$panel/$sampleId/hotspot_coverage/*.totalCoverage
    rm /data/results/$seqId/$panel/$sampleId/hotspot_coverage/*combined*

fi

rm vendorCaptureBed_100pad.bed
rm *interval_statistics
rm *interval_summary
rm *sample_statistics