#!/bin/bash

#SBATCH --time=12:00:00
#SBATCH --output=SomaticEnrichment-%N-%j.output
#SBATCH --error=SomaticEnrichment-%N-%j.error
#SBATCH --partition=high
#SBATCH --cpus-per-task=40

# Description: Somatic Enrichment Pipeline. Requires fastq file split by lane
# Author:      AWMGS
# Mode:        BY_SAMPLE
# Use:         sbatch within sample directory

cd "$SLURM_SUBMIT_DIR"

version="2.0.0"

# load sample variables
. *.variables

# setup local scratch
SCRATCH_DIR=/localscratch/"$SLURM_JOB_ID"/"$seqId"/"$worklistId"/"$panel"/"$sampleId"
mkdir -p "$SCRATCH_DIR" && cd "$SCRATCH_DIR"

# setup temp dir
mkdir tmpdir

# link fastq / variables files to scratch
ln -s $SLURM_SUBMIT_DIR/* .

# copy library resources
pipeline_dir=/data/diagnostics/pipelines/"$pipelineName"/"$pipelineName"-"$pipelineVersion"
cp -r "$pipeline_dir"/SomaticEnrichmentLib-"$version" .
cp "$pipeline_dir"/"$panel"/"$panel".variables .

# load pipeline variables
. "$panel".variables

# path to panel capture bed file
vendorCaptureBed=/data/diagnostics/pipelines/"$pipelineName"/"$pipelineName"-"$pipelineVersion"/"$panel"/180702_HG19_PanCancer_EZ_capture_targets.bed
vendorPrimaryBed=/data/diagnostics/pipelines/"$pipelineName"/"$pipelineName"-"$pipelineVersion"/"$panel"/180702_HG19_PanCancer_EZ_primary_targets.bed

# activate conda env
module purge
module load anaconda
source activate SomaticEnrichment

set -euo pipefail

# define fastq variables
for fastqPair in $(ls "$sampleId"_S*.fastq.gz | cut -d_ -f1-3 | sort | uniq)
do
    
    laneId=$(echo "$fastqPair" | cut -d_ -f3)
    read1Fastq=$(ls "$fastqPair"_R1_*fastq.gz)
    read2Fastq=$(ls "$fastqPair"_R2_*fastq.gz)

    # cutadapt
    ./SomaticEnrichmentLib-"$version"/cutadapt.sh \
        $seqId \
        $sampleId \
        $laneId \
        $read1Fastq \
        $read2Fastq \
        $read1Adapter \
        $read2Adapter

    # fastqc
    ./SomaticEnrichmentLib-"$version"/fastqc.sh $seqId $sampleId $laneId

     # fastq to ubam
    ./SomaticEnrichmentLib-"$version"/fastq_to_ubam.sh \
        $seqId \
        $sampleId \
        $laneId \
        $worklistId \
        $panel \
        $expectedInsertSize

    # bwa
    ./SomaticEnrichmentLib-"$version"/bwa.sh $seqId $sampleId $laneId
    
done

# merge & mark duplicate reads
./SomaticEnrichmentLib-"$version"/mark_duplicates.sh $seqId $sampleId 

# rename bam files
mv "$seqId"_"$sampleId"_rmdup.bam "$seqId"_"$sampleId".bam
mv "$seqId"_"$sampleId"_rmdup.bai "$seqId"_"$sampleId".bai

# post-alignment QC
./SomaticEnrichmentLib-"$version"/post_alignment_qc.sh \
    $seqId \
    $sampleId \
    $panel \
    $minimumCoverage \
    $vendorCaptureBed \
    $vendorPrimaryBed \
    $padding \
    $minBQS \
    $minMQS

# coverage calculations
#./SomaticEnrichmentLib-"$version"/hotspot_coverage.sh \
#    $seqId \
#    $sampleId \
#    $panel \
#    $pipelineName \
#    $pipelineVersion \
#    $minimumCoverage \
#    $vendorPrimaryBed \
#    $padding \
#    $minBQS \
#    $minMQS

# variant calling
./SomaticEnrichmentLib-"$version"/mutect2.sh $seqId $sampleId $pipelineName $version $panel $padding $minBQS $minMQS $vendorPrimaryBed

# variant filter
./SomaticEnrichmentLib-"$version"/variant_filter.sh $seqId $sampleId $panel $minBQS $minMQS

# annotation
# check that there are called variants to annotate
if [ $(grep -v "#" "$seqId"_"$sampleId"_filteredStrLeftAligned.vcf | grep -v '^ ' | wc -l) -ne 0 ]; then
    ./SomaticEnrichmentLib-"$version"/annotation.sh $seqId $sampleId $panel
else
    mv "$seqId"_"$sampleId"_filteredStrLeftAligned.vcf "$seqId"_"$sampleId"_filteredStrLeftAligned_annotated.vcf
fi

# generate variant reports
./SomaticEnrichmentLib-"$version"/hotspot_variants.sh $seqId $sampleId $panel $pipelineName $pipelineVersion

# run manta for all samples except NTC
if [ $sampleId != 'NTC' ]; then 
    ./SomaticEnrichmentLib-"$version"/manta.sh $seqId $sampleId $panel $vendorPrimaryBed
fi

# migrate data from scratch to results location
cp "$seqId"_"$sampleId"_filteredStrLeftAligned_annotated.vcf $SLURM_SUBMIT_DIR
cp "$seqId"_"$sampleId".bam $SLURM_SUBMIT_DIR
cp "$seqId"_"$sampleId".bai $SLURM_SUBMIT_DIR
cp "$seqId"_"$sampleId"_HsMetrics.txt $SLURM_SUBMIT_DIR
cp "$seqId"_"$sampleId"_InsertMetrics.txt $SLURM_SUBMIT_DIR
cp "$sampleId"_VariantReport.txt $SLURM_SUBMIT_DIR
cp -r hotspot_variants $SLURM_SUBMIT_DIR
cp -r MANTA $SLURM_SUBMIT_DIR
cp -r FASTQC $SLURM_SUBMIT_DIR

cd $SLURM_SUBMIT_DIR

# add samplename to run-level file if vcf detected
if [ -e "$seqId"_"$sampleId"_filteredStrLeftAligned_annotated.vcf ]
then
    echo $sampleId >> ../sampleVCFs.txt    
fi

# ---------------------------------------------------------------------------------------------------------
#  RUN LEVEL ANALYSES
# ---------------------------------------------------------------------------------------------------------

#numberSamplesInVcf=$(cat ../sampleVCFs.txt | uniq | wc -l)
#numberSamplesInProject=$(find ../ -maxdepth 2 -mindepth 2 | grep .variables | uniq | wc -l)

# only the last sample to complete SNV calling will run the following
if [ $numberSamplesInVcf -eq $numberSamplesInProject ]
then

    # run cnv kit
    echo "running CNVKit as $numberSamplesInVcf samples have completed SNV calling"
    ./SomaticEnrichmentLib-"$version"/cnvkit.sh $seqId $panel $vendorPrimaryBed $version

    # generate worksheets
    ./SomaticEnrichmentLib-"$version"/make_variant_report.sh $seqId $panel

    # pull all the qc data together and generate combinedQC.txt
    ./SomaticEnrichmentLib-"$version"/compileQcReport.sh $seqId $panel

else
    echo "not all samples have completed running. Finishing process for this sample."
fi
