// Per-barcode read QC figures, published alongside the reads.
//
// Purpose is a mid-run stop/continue decision: is this run producing enough
// bases, on the right read lengths, spread evenly enough across barcodes, to be
// worth continuing? That question has to be answerable from a browser while the
// sequencer is still running, so the output is static HTML in the run's own
// output prefix (fastq_pass/, fastq_fail/, read_figures/ as siblings).
//
// Driven off the demuxed FASTQs rather than a dorado summary TSV on purpose:
// dorado_summary only runs for duplex (see ingress.nf), so on a simplex sup run
// there is no per-read stats file to plot from, whereas the demuxed reads are
// exactly what downstream analysis will consume.

// Per-barcode stats table + read-length/quality figures.
process read_figures_per_barcode {
    label "wf_basecalling"
    cpus params.stats_threads
    memory "16GB"
    publishDir "${params.out_dir}/read_figures/${filetag}",
        mode: 'copy',
        pattern: "${barcode}/*"
    input:
        tuple val(barcode), path(reads, stageAs: "reads/*")
        val filetag // "pass" or "fail" — keeps the two arms in separate subtrees
    output:
        tuple val(barcode), path("${barcode}/${barcode}.stats.tsv"), emit: stats
        path("${barcode}/*"), emit: figures
    script:
    """
    mkdir -p ${barcode}

    # seqkit gives reads / total bases / N50 / length quantiles / mean quality in
    # one pass. -a is the "all" stat set, which is what the index table needs.
    seqkit stats -a -T -j ${task.cpus} reads/* > ${barcode}/${barcode}.stats.tsv

    # NanoPlot draws the distributions. It exits non-zero on an empty or tiny
    # barcode, which is a normal outcome for an unused barcode rather than a run
    # failure, so a failure here must not take the whole workflow down — the
    # stats TSV above is still produced and the index still renders.
    NanoPlot \\
        --fastq reads/* \\
        --outdir ${barcode} \\
        --prefix ${barcode}. \\
        --threads ${task.cpus} \\
        --N50 \\
        --tsv_stats \\
        --no_static \\
        --title "${params.sample_name} ${barcode} (${filetag})" \\
        || echo "NanoPlot produced no figures for ${barcode}; stats TSV retained"
    """
}

// One HTML index across all barcodes: the page you actually open mid-run.
process read_figures_index {
    label "wf_basecalling"
    cpus 1
    memory "4GB"
    publishDir "${params.out_dir}/read_figures/${filetag}",
        mode: 'copy',
        pattern: "index.html"
    input:
        path(stats_tsvs, stageAs: "stats/*")
        val filetag
    output:
        path("index.html")
    script:
    """
    build_read_figures_index.py \\
        --stats stats/* \\
        --sample-name "${params.sample_name}" \\
        --filetag "${filetag}" \\
        --output index.html
    """
}

// Groups demuxed reads by barcode, then fans out figures and folds the
// per-barcode stats into a single index page.
workflow read_figures {
    take:
        demuxed_reads // flat channel of demuxed/<sample>/<run>/fastq_*/<barcode>/<file>
        filetag
    main:
        // The barcode is the name of each file's parent directory; grouping on it
        // reassembles per-barcode read sets without threading barcode identity
        // through the demux process.
        by_barcode = demuxed_reads
            .flatten()
            .map { read -> tuple(read.parent.name, read) }
            .groupTuple()

        per_barcode = read_figures_per_barcode(by_barcode, filetag)
        index = read_figures_index(per_barcode.stats.map { bc, tsv -> tsv }.collect(), filetag)
    emit:
        stats = per_barcode.stats
        index = index
}
