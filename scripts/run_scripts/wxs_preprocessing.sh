#!/bin/bash

# The purpose of this script is to run the LosicLab's custom fork of nextflow's wholeexome sequencing processing pipeline for fastq->vcf.


# specify account for lsf runs
#account='acc_JanssenIBD' # do not leave this to default unless running interactive profile
#job_queue='premium' #default queue is alloc

# Run directory. Pipeline outputs to $rundir/preprocessing
rundir=$PWD"/testdata/tiny"


# Reference genome to use [Default: GRCh38; other refs not yet supported]
ref="GRCh38"

# Path to directory containing the pipeline to run
pipeline='/sc/orga/projects/losicb01a/common_folder/nextflow-pipelines/sandbox/exoseq'
#mkdir -p $rundir
cd $rundir

inputfq="tiny*{R1,R2}*.fastq.gz"

module purge
module load openssl
module load anaconda
module load nextflow/0.30.2

nextflow run $pipeline/preprocessing.nf \
--outdir $rundir \
--reads "$inputfq" \
--genome $ref \
--notrim "true" \
--saveAlignedIntermediates "true" \
-resume \
-profile chimera_local # local | minerva
