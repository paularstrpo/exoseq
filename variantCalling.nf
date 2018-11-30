#!/usr/bin/env nextflow


/*
========================================================================================
               nf-core/ E X O S E Q    B E S T    P R A C T I C E
========================================================================================
 #### Homepage / Documentation
 https://github.com/scilifelab/NGI-ExoSeq
 #### Authors
 Senthilkumar Panneerselvam @senthil10 <senthilkumar.panneerselvam@scilifelab.se>
 Phil Ewels @ewels <phil.ewels@scilifelab.se>
 Alex Peltzer @alex_peltzer <alexander.peltzer@qbic.uni-tuebingen.de>
 Marie Gauder <marie.gauder@student.uni-tuebingen.de>

 Some code parts were lent from other NGI-Pipelines (e.g. CAW), specifically the error
 handling, logging messages. Thanks for that @CAW guys.
----------------------------------------------------------------------------------------
Developed based on GATK's best practise, takes set of FASTQ files and performs:
 - alignment (BWA)
 - recalibration (GATK)
 - realignment (GATK)
 - variant calling (GATK)
 - variant evaluation (SnpEff)
*/

// Help message
helpMessage = """
===============================================================================
nf-core/ExoSeq : Exome/Targeted sequence capture best practice analysis v${params.version}
===============================================================================

Usage: nextflow </path/to/pipelines/exoseq> --reads '*_R{1,2}.fastq.gz' --genome GRCh37 --sampleID 'sample_name'

This is a typical usage where the required parameters (with no defaults) were
given. It is recommended to process one sample per nextflow run.

The available paramaters are listed below based on category

Required parameters:
    --reads                       Absolute path to input fastq file for sample (MUST use regex '*' in name)
    --genome                      Name of Genome reference, [Default: 'GRCh38']
    --sampleID                    Name of Sample

Required if running minerva profile:
    --minerva_account             name of fund for minerva to charge lsf jobs to
    --job_queue                   job queue to submit to [Default: 'alloc']

Output:
    --outdir                      Path where the results to be saved [Default: use sampleID as directory name]
    -w/--work-dir                 The temporary directory where intermediate data will be saved

Optional Parameters:
    -profile                      load custom profile ['standard' | 'minerva' ; Default: 'standard']
    --name                        custom run name?
    --help                        show help message & exit
    --singleEnd                   input reads are single-end [Default: paired-end]
    --multiLane                   specify if you have mutliple lanes per sample that need to be concatenated. [Default: true]
    --saveAlignedIntermediates    [Default: false]
    --saveIntermediateVariants    [Default: false]

For more detailed information regarding the parameters and usage refer to package
documentation at https://github.com/nf-core/ExoSeq""".stripIndent()

// Variables and defaults
params.name = false
params.help = false
params.reads = false
params.genome = 'GRCh38'
params.singleEnd = false
params.run_id = false
params.saveReference = true
params.exome = true
params.kitfiles = 'agilent_v5'
params.sampleID = 'sampleID'
params.multiLane = true
params.aligner = "bwa"

// Output configuration
params.outdir = "./variantcall"
params.saveAlignedIntermediates = false
params.saveIntermediateVariants = false



// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}

// Show help when needed
if (params.help){
    log.info helpMessage
    exit 0
}

// Check blocks for certain required parameters, to see they are given and exist
if (!params.reads || !params.genome){
    exit 1, "Parameters '--reads' and '--genome' are required to run the pipeline"
}

if (!params.refs){
    exit 1, "No Exome Metafiles specified!"
}



// Create a channel for input files
Channel
    .fromFilePairs( params.reads, size: params.singleEnd ? 1 : 2 )
    .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\nIf this is single-end data, please specify --singleEnd on the command line." }
    .into { read_files_fastqc; read_files_trimming }


// Validate Input indices for BWA Mem and GATK
if(params.aligner == 'bwa' ){
    bwaId = Channel
        .fromPath("${params.gfasta}.bwt")
        .ifEmpty { exit 1, "BWA index not found: ${params.gfasta}.bwt" }
}


// Create a summary for the logfile
def summary = [:]
summary['Run Name']     = custom_runName ?: workflow.runName
summary['Reads']        = params.reads
summary['Data Type']    = params.singleEnd ? 'Single-End' : 'Paired-End'
summary['Genome Assembly']       = params.genome
summary['Trim R1'] = params.clip_r1
summary['Trim R2'] = params.clip_r2
summary["Trim 3' R1"] = params.three_prime_clip_r1
summary["Trim 3' R2"] = params.three_prime_clip_r2
if(params.aligner == 'bwa'){
    summary['Aligner'] = "BWA Mem"
    if(params.bwa_index)          summary['BWA Index']   = params.bwa_index
    else if(params.gfasta)          summary['Fasta Ref']    = params.gfasta
}
summary['Save Intermediate Aligneerged_bam) from mergedBam
d Files'] = params.saveAlignedIntermediates ? 'Yes' : 'No'
summary['Save Intermediate Variant Files'] = params.saveIntermediateVariants ? 'Yes' : 'No'
summary['Max Memory']     = params.max_memory
summary['Max CPUs']       = params.max_cpus
summary['Max Time']       = params.max_time
summary['Output dir']     = params.outdir
summary['Working dir']    = workflow.workDir
summary['Container']      = workflow.container
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Current home']   = "$HOME"
summary['Current user']   = "$USER"
summary['Current path']   = "$PWD"
summary['Script dir']     = workflow.projectDir
summary['Config Profile'] = workflow.profile
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="

try {
    if( ! workflow.nextflow.version.matches(">= $params.nf_required_version") ){
        throw GroovyException('Nextflow version too old')
        }
} catch (all) {
    log.error "====================================================\n" +
              "  Nextflow version $params.nf_required_version required! You are running v$workflow.nextflow.version.\n" +
              "  Pipeline execution will continue, but things may break.\n" +
              "  Please run `nextflow self-update` to update Nextflow.\n" +
              "============================================================"
}




/*
 * Step 8 - Call Variants with HaplotypeCaller in GVCF mode (differentiate between exome and whole genome data here)
 *
*/

process variantCall {
    tag "${name}"
    publishDir "${params.outdir}/GATK_VariantCalling/", mode: 'symlink',
        saveAs: {filename -> filename.replaceFirst(/variants/, "raw_variants")}

    input:
    set val(name), file(realign_bam), file(realign_bam_ind) from bam_vcall

    output:
    set val(name), file("${name}_variants.vcf"), file("${name}_variants.vcf.idx") into raw_variants_GATK, raw_variants_vep

    script:
    if(params.exome){
    """
    gatk HaplotypeCaller \\
        -I $realign_bam \\
        -R $params.gfasta \\
        -O ${name}_variants.vcf \\
        -ERC GVCF \\
        -L $params.target \\
        --create-output-variant-index \\
        --annotation MappingQualityRankSumTest \\
        --annotation QualByDepth \\
        --annotation ReadPosRankSumTest \\
        --annotation RMSMappingQuality \\
        --annotation FisherStrand \\
        --annotation Coverage \\
        --dbsnp $params.dbsnp \\
        --verbosity INFO \\
        --java-options -Xmx${task.memory.toGiga()}g
    """
    } else { // We have a winner (genome)
    """
    gatk HaplotypeCaller \\
        -I $realign_bam \\
        -R $params.gfasta \\
        -O ${name}_variants.vcf \\
        -ERC GVCF \\
        --create-output-variant-index \\
        --annotation MappingQualityRankSumTest \\
        --annotation QualByDepth \\
        --annotation ReadPosRankSumTest \\
        --annotation RMSMappingQuality \\
        --annotation FisherStrand \\
        --annotation Coverage \\
        --dbsnp $params.dbsnp \\
        --verbosity INFO \\
        --java-options -Xmx${task.memory.toGiga()}g
    """
    }
}




/*
================================================================================
=                               F U N C T I O N S                              =
================================================================================
*/

def exoMessage() {
  // Display ExoSeq message
  log.info "nf-core/ExoSeq ANALYSIS WORKFLOW ~ ${params.version} - " + this.grabRevision() + (workflow.commitId ? " [${workflow.commitId}]" : "")
}

def grabRevision() {
  // Return the same string executed from github or not
  return workflow.revision ?: workflow.commitId ?: workflow.scriptId.substring(0,10)
}

def minimalInformationMessage() {
  // Minimal information message
  log.info "Command Line: " + workflow.commandLine
  log.info "Project Dir : " + workflow.projectDir
  log.info "Launch Dir  : " + workflow.launchDir
  log.info "Work Dir    : " + workflow.workDir
  log.info "Out Dir     : " + params.outdir
  log.info "Genome      : " + params.gfasta
}

def nextflowMessage() {
  // Nextflow message (version + build)
  log.info "N E X T F L O W  ~  version ${workflow.nextflow.version} ${workflow.nextflow.build}"
}

def versionMessage() {
  // Display version message
  log.info "nf-core/ExoSeq ANALYSIS WORKFLOW"
  log.info "  version   : " + version
  log.info workflow.commitId ? "Git info    : ${workflow.repository} - ${workflow.revision} [${workflow.commitId}]" : "  revision  : " + this.grabRevision()
}


workflow.onComplete {
  // Display complete message
  this.nextflowMessage()
  this.exoMessage()
  this.minimalInformationMessage()
  log.info "Completed at: " + workflow.complete
  log.info "Duration    : " + workflow.duration
  log.info "Success     : " + workflow.success
  log.info "Exit status : " + workflow.exitStatus
  log.info "Error report: " + (workflow.errorReport ?: '-')
}

workflow.onError {
  // Display error message
  this.nextflowMessage()
  this.exoMessage()
  log.info "Workflow execution stopped with the following message:"
  log.info "  " + workflow.errorMessage
}