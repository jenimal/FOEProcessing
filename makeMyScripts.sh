#!/bin/bash
#
# makeMyScripts.sh — regenerate the job-script template (the file doCondor.py
# copies into condor_jobs/<name>/my_script.sh) for a given dataset.
#
# submit_condor_jobs.py rewrites this template from scratch on every run, but if
# the file was deleted during cleanup, or you only want to resubmit a few jobs
# for one dataset, this recreates it identically.
#
# Usage:
#   ./makeMyScripts.sh <DATASET> [--type data|mc] [--out <path>]
#
# Default output: condor_script_templates/script_temp.sh
# Data vs MC auto-detected from the dataset name (CMS_mc_ prefix -> MC);
# override with --type.
#
# For a resub, point doCondor.py at the output with:  -s <out>

set -u

DATASET=""
TYPE=""
OUT="condor_script_templates/script_temp.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --type) TYPE="$2"; shift 2 ;;
        --out)  OUT="$2";  shift 2 ;;
        -h|--help) echo "Usage: $0 <DATASET> [--type data|mc] [--out <path>]"; exit 0 ;;
        *)
            if [ -z "$DATASET" ]; then
                DATASET="$1"; shift
            else
                echo "Unexpected argument: $1"; exit 1
            fi
            ;;
    esac
done

[ -z "$DATASET" ] && { echo "Usage: $0 <DATASET> [--type data|mc] [--out <path>]"; exit 1; }
DATASET="${DATASET%.txt}"

case "$TYPE" in
    "")
        if [[ "$DATASET" == CMS_mc_* ]]; then KIND=MC; else KIND=data; fi
        ;;
    data|Data|DATA) KIND=data ;;
    mc|MC|Mc)        KIND=MC ;;
    *) echo "Unknown --type '$TYPE' (use data or mc)"; exit 1 ;;
esac

if [ -d "$OUT" ]; then
    OUT="$OUT/my_script.sh"
    echo "  --out is a directory; writing to: $OUT"
fi

echo "Dataset: $DATASET  ($KIND)"
echo "Output:  $OUT"

mkdir -p "$(dirname "$OUT")"
cp condor_script_templates/h5_template.sh "$OUT"

{
    if [ "$KIND" = "MC" ]; then
        echo "cmsRun pfnano_mc_2016UL_OpenData.py inputFiles_load=EOS_files_split/${DATASET}/${DATASET}_job\${2}.txt"
        echo "python H5_maker_FOE.py -i nano_mc2016post.root -o ${DATASET}_job\${2}.h5 --sample_type MC"
    else
        echo "cmsRun pfnano_data_2016UL_OpenData.py inputFiles_load=EOS_files_split/${DATASET}/${DATASET}_job\${2}.txt"
        echo "python H5_maker_FOE.py -i nano_data2016.root -o ${DATASET}_job\${2}.h5 -j Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt"
    fi
    echo "xrdcp -f ${DATASET}_job\${2}.h5 \${1}"
} >> "$OUT"

chmod +x "$OUT"

echo "Contents:"
cat "$OUT" | sed 's/^/    /'
echo ""
echo "For a resub, pass: python3 doCondor.py ... --resub -s $OUT"