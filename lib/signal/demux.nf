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
    // 4 rather than 1 so the gzip pass below fans out across a barcode's files
    // with xargs -P. A chunk's demuxed output runs to a couple of GB, which is
    // a minute or so single-threaded and a fraction of that here.
    cpus 4
    memory "14.4GB"
    publishDir "${params.out_dir}",
        mode: 'copy',
        pattern: "demuxed/**/*.${output_extension}",
        saveAs: { fn ->
            // dorado emits a deeper tree than it documents. Observed on a real run:
            //   demuxed/<experiment>/<sample>/<run>/fastq_pass/<barcode>/<file>.fastq
            // We flatten that to:
            //   fastq_<filetag>/<barcode>/<file>.fastq.gz
            //
            // The experiment/sample/run segments must go. The watcher resolves reads
            // at <out_dir>/fastq_pass/<barcode>/ (survey_analysis'
            // _derive_cloud_nanopore_read_dir) and knows nothing about them, so
            // leaving them in place publishes reads that no downstream barcode can
            // find — which is exactly what the first live run produced.
            //
            // Both the directory AND the filename take the arm we actually fed in,
            // not the label dorado chose. dorado tags every emitted file "pass"
            // regardless of arm, so keeping its label yields
            // fastq_fail/barcode33/..._pass_....fastq — a file whose name
            // contradicts its own directory. The arm is known here with certainty.
            def parts = fn.tokenize('/')
            def barcode = parts.size() >= 2 ? parts[-2] : 'unclassified'
            def name = parts[-1].replaceFirst(/_(pass|fail)_/, "_${filetag}_")
            // publish_tag keeps concurrent jobs sharing one --out_dir from
            // overwriting each other: dorado indexes per invocation, so every
            // job would otherwise emit the same name for the same barcode.
            def tag = params.publish_tag ? "${params.publish_tag}_" : ""
            "fastq_${filetag}/${barcode}/${tag}${name}"
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
    output_extension = output_fmt == "fastq" ? "fastq.gz" : "bam"  // nodef: used in output
    // dorado writes UNCOMPRESSED fastq and offers no way to change that:
    // --emit-fastq selects the format only, and demux takes --output-dir rather
    // than an output filename, so there is no htslib "compress by extension"
    // hook — which is how merge_calls_to_fastq gets its .fq.gz for free from
    // `samtools bam2fq -0 "${params.sample_name}.${filetag}.fq.gz"`.
    //
    // So compress in the task, before publishDir copies anything: on a cloud
    // run out_dir is a gs:// bucket, and the point is that nothing uncompressed
    // is ever written there. Everything downstream assumes gzip — MinKNOW emits
    // .fastq.gz, and the watcher's read_counter opens reads with gzip.open and
    // swallows BadGzipFile, so a plain .fastq silently counts as zero reads.
    //
    // Mixing is the sharp edge. NANOPLOT cats a barcode's files together, so a
    // dir holding both plain and gzipped reads — exactly what you get when part
    // of a run is basecalled locally and the backlog is basecalled in the cloud,
    // the case this workflow exists for — yields text concatenated with gzip
    // members, which readers truncate at the boundary instead of failing.
    def compress = output_fmt == "fastq"
        ? "find demuxed -name '*.fastq' -print0 | xargs -0 -r -P ${task.cpus} gzip -n"
        : ""
    """
    dorado demux --output-dir demuxed ${is_aligned} ${emit_fastq} --no-classify --recursive crams
    ${compress}
    """
}
