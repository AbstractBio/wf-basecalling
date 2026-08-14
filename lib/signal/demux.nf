// Demultiplexing of basecalled reads into per-barcode files.
//
// Split out of ingress.nf so the process can be imported twice under different
// aliases — once for the pass arm and once for the fail arm — mirroring how
// merge.nf's merge_calls is aliased into merge_pass_calls / merge_fail_calls.
// A process can only be invoked once per workflow unless it is aliased on
// import, which is why this lives in its own module rather than in ingress.nf.

// if demuxing, split the BAMs
process split_calls {
    label "wf_basecalling"
    label "wf_dorado"
    cpus 1
    memory "14.4GB"
    publishDir "${params.out_dir}",
        mode: 'copy',
        pattern: "demuxed/**/*.${output_extension}",
        saveAs: { fn ->
            // dorado emits: demuxed/sample_id/run_id/fastq_pass/barcode01/file.fastq
            // published as:          sample_id/run_id/fastq_<filetag>/barcode01/file.fastq
            //
            // The pass/fail segment is rewritten to the arm we actually fed in rather
            // than kept as dorado labelled it. Both arms are demuxed through the same
            // process, and dorado derives that segment from the read metadata, so the
            // fail arm would otherwise land under fastq_pass/ and overwrite the pass
            // arm's output. The arm is known here with certainty; dorado's label is not.
            fn.replaceFirst("demuxed/", "")
              .replaceFirst(/fastq_(pass|fail)/, "fastq_${filetag}")
        }
    input:
        path(cram, stageAs: "crams/*")
        tuple path(ref_cache), env(REF_PATH)
        val output_fmt
        val filetag // "pass" or "fail" — selects the published fastq_*/ root
    output:
        path("demuxed/**/*.${output_extension}")
    script:
    // CW-4509: as described [here](https://github.com/nanoporetech/dorado#Demultiplexing-mapped-reads)
    // to preserve mapping information when demuxing, we need to ask for
    // `--no-trim`. Being aligned, it is also worth ask for it to be sorted/indexed.
    def is_aligned = params.ref ? "--no-trim --sort-bam" : ""
    def emit_fastq = output_fmt == "fastq" ? "--emit-fastq" : ""
    output_extension = output_fmt == "fastq" ? "fastq" : "bam"  // nodef: used in output
    """
    dorado demux --output-dir demuxed ${is_aligned} ${emit_fastq} --no-classify --recursive crams
    """
}
