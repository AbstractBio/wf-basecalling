#!/usr/bin/env python
"""Fold per-barcode seqkit stats into one HTML index for mid-run QC.

The page answers the question a stop/continue decision needs: how many bases has
each barcode produced, at what read lengths, and how evenly is yield spread? It
is deliberately a single self-contained file with no external assets, because it
is read straight from a gs:// prefix.
"""

import argparse
import html
from pathlib import Path


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

def parse_seqkit_stats(path):
    """Return one summed record per barcode from a seqkit `stats -a -T` TSV.

    seqkit emits one row per input file; a barcode usually has many. Counts and
    bases sum across rows, but N50 and mean length cannot be averaged
    meaningfully, so the value from the largest file is carried as an estimate
    and labelled as such in the table header.
    """
    lines = Path(path).read_text().strip().splitlines()
    if len(lines) < 2:
        return None

    header = lines[0].split("\t")
    rows = [dict(zip(header, line.split("\t"))) for line in lines[1:]]

    def as_number(value, cast):
        try:
            return cast(value)
        except (TypeError, ValueError):
            return 0

    total_reads = sum(as_number(r.get("num_seqs"), int) for r in rows)
    total_bases = sum(as_number(r.get("sum_len"), int) for r in rows)
    largest = max(rows, key=lambda r: as_number(r.get("sum_len"), int))

    return {
        "barcode":     Path(path).name.split(".")[0],
        "reads":       total_reads,
        "bases":       total_bases,
        "mean_length": as_number(largest.get("avg_len"), float),
        "n50":         as_number(largest.get("N50"), int),
        "mean_qual":   as_number(largest.get("AvgQual"), float),
    }


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

def human_bases(n):
    for unit, size in (("Gb", 1e9), ("Mb", 1e6), ("kb", 1e3)):
        if n >= size:
            return f"{n / size:.2f} {unit}"
    return f"{n} bp"


def render_html(records, sample_name, filetag):
    """Return a self-contained HTML page. No external assets: it is read from GCS."""
    records = sorted(records, key=lambda r: r["barcode"])
    total_bases = sum(r["bases"] for r in records)
    total_reads = sum(r["reads"] for r in records)

    # A yield bar per barcode makes imbalance visible at a glance, which is the
    # single most actionable thing on this page mid-run.
    max_bases = max((r["bases"] for r in records), default=0) or 1

    rows = []
    for record in records:
        share = 100.0 * record["bases"] / total_bases if total_bases else 0.0
        bar_width = 100.0 * record["bases"] / max_bases
        barcode = html.escape(record["barcode"])
        rows.append(f"""
        <tr>
          <td><a href="{barcode}/">{barcode}</a></td>
          <td class="n">{record['reads']:,}</td>
          <td class="n">{human_bases(record['bases'])}</td>
          <td class="n">{share:.1f}%</td>
          <td class="n">{record['mean_length']:,.0f}</td>
          <td class="n">{record['n50']:,}</td>
          <td class="n">{record['mean_qual']:.1f}</td>
          <td class="bar"><div style="width:{bar_width:.1f}%"></div></td>
        </tr>""")

    return f"""<!doctype html>
<html><head><meta charset="utf-8">
<title>{html.escape(sample_name)} — read figures ({html.escape(filetag)})</title>
<style>
  body {{ font-family: system-ui, sans-serif; margin: 2rem; max-width: 1100px; }}
  h1 {{ font-size: 1.4rem; margin-bottom: .2rem; }}
  .sub {{ color: #666; margin-bottom: 1.5rem; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ padding: .45rem .6rem; border-bottom: 1px solid #e3e3e3; text-align: left; }}
  th {{ background: #fafafa; font-weight: 600; }}
  td.n {{ text-align: right; font-variant-numeric: tabular-nums; }}
  td.bar {{ width: 22%; }}
  td.bar div {{ background: #4a7ebb; height: 12px; border-radius: 2px; }}
  tfoot td {{ font-weight: 600; }}
</style></head>
<body>
<h1>{html.escape(sample_name)} — read figures</h1>
<div class="sub">
  {html.escape(filetag)} reads · {len(records)} barcodes ·
  {total_reads:,} reads · {human_bases(total_bases)} total
</div>
<table>
  <thead><tr>
    <th>Barcode</th><th class="n">Reads</th><th class="n">Bases</th>
    <th class="n">Share</th><th class="n">Mean len*</th><th class="n">N50*</th>
    <th class="n">Mean Q*</th><th>Yield</th>
  </tr></thead>
  <tbody>{''.join(rows)}</tbody>
  <tfoot><tr>
    <td>Total</td><td class="n">{total_reads:,}</td>
    <td class="n">{human_bases(total_bases)}</td>
    <td class="n">100.0%</td><td colspan="4"></td>
  </tr></tfoot>
</table>
<p class="sub">* Length, N50 and quality are taken from each barcode's largest
file rather than pooled — these statistics cannot be averaged across files.
Follow a barcode link for its full NanoPlot distributions.</p>
</body></html>
"""


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stats", nargs="+", required=True,
                        help="per-barcode seqkit stats TSVs")
    parser.add_argument("--sample-name", required=True)
    parser.add_argument("--filetag", required=True, help="pass or fail")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    records = [r for r in (parse_seqkit_stats(p) for p in args.stats) if r]
    Path(args.output).write_text(render_html(records, args.sample_name, args.filetag))


if __name__ == "__main__":
    main()
