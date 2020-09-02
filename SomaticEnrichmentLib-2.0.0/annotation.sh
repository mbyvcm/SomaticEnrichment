#!/bin/bash
set -euo pipefail

# Christopher Medway AWMGS
# variant annotation with VEP

seqId=$1
sampleId=$2
panel=$3

module load anaconda

set +u 
source activate VEP-100
set -u

vep \
    --input_file "$seqId"_"$sampleId"_filteredStrLeftAligned.vcf \
    --format vcf \
    --output_file "$seqId"_"$sampleId"_filteredStrLeftAligned_annotated.vcf \
    --vcf \
    --everything \
    --fork 12 \
    --assembly GRCh37 \
    --no_intergenic \
    --no_progress \
    --allele_number \
    --no_escape \
    --shift_hgvs 1 \
    --cache \
    --cache_version 100 \
    --force_overwrite \
    --no_stats \
    --offline \
    --dir /home/transfer/resources/human/vep-cache/refseq37_v100 \
    --fasta /home/transfer/resources/human/gatk/2.8/b37/human_g1k_v37.fasta \
    --species homo_sapiens \
    --refseq \
    --custom /home/transfer/resources/human/gnomad/gnomad.exomes.r2.0.1.sites.vcf.gz,GNOMAD,vcf,exact,0,AF \
    --custom /home/transfer/resources/human/cosmic/b37/cosmic_78.b37.vcf.gz,COSMIC,vcf,exact,0

set +u
conda deactivate
source activate SomaticEnrichment
set -u

# index and validation
gatk --java-options "-XX:GCTimeLimit=50 -XX:GCHeapFreeLimit=10 -Djava.io.tmpdir=./tmpdir -Xmx4g" \
    IndexFeatureFile \
    -F "$seqId"_"$sampleId"_filteredStrLeftAligned_annotated.vcf
