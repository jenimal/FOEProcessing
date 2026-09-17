#!/bin/bash
#
# verify_condor_jobs.sh — after a batch of condor jobs, report which jobs
# produced their .h5 output, which are still queued/running, and which have
# failed so they can be re-run. Run OUTSIDE singularity, from FOEProceessing/.
#
# Usage:
#   ./verify_condor_jobs.sh                    # verify every dataset in EOS_files_split/
#   ./verify_condor_jobs.sh <dataset> [...]    # verify specific dataset(s)
#
# A job is considered:
#   OK       -> <dataset>_job<i>.h5 is present on EOS
#   RUNNING  -> no .h5 yet, but the dataset still appears in condor_q
#   FAILED   -> no .h5 yet, and not queued anymore (finished badly / never ran)
#
# To re-run failed jobs (after confirming nothing is still active):
#   python3 doCondor.py -n <dataset> -d <dataset> --nJobs <N> --resub --overwrite --mem 6000 -s condor_script_templates/script_temp.sh
# (N = number of per-job .txt lists under EOS_files_split/<dataset>/.)
# NOTE: -d is REQUIRED so the regenerated workers xrdcp the dataset-specific
# tarball (OPENDATA_CMSSW_<dataset>.tgz); without it they fetch the generic
# OPENDATA_CMSSW.tgz, which lacks this dataset's split lists -> Bad filename.
#
# This only reports on jobs that were split with split_file_list.py, i.e. the
# per-job lists under EOS_files_split/<dataset>/ are the source of truth for
# how many jobs each dataset should have produced.

EOS_ROOT="root://cmseos.fnal.gov"
EOS_OUT="${FOE_EOS_STORE:-/store/group/lpctreasure}/Condor_outputs"

# ─── Which datasets to check ─────────────────────────────────────────────
if [ $# -eq 0 ]; then
    DATASETS=()
    for d in EOS_files_split/*/; do
        [ -d "$d" ] && DATASETS+=("$(basename "$d")")
    done
    if [ ${#DATASETS[@]} -eq 0 ]; then
        echo "No datasets found under EOS_files_split/. Pass dataset names as arguments."
        echo "Usage: $0 [dataset1 ...]"
        exit 1
    fi
else
    DATASETS=("$@")
fi

# One snapshot of the queue for all datasets (avoids one condor_q per dataset).
ACTIVE=$(condor_q 2>/dev/null || true)

G_OK=0; G_RUN=0; G_FAIL=0
declare -a FAILED_DATASETS=()

for DATASET in "${DATASETS[@]}"; do
    SPLIT_DIR="EOS_files_split/${DATASET}"
    if [ ! -d "$SPLIT_DIR" ]; then
        echo "[SKIP] $DATASET — no EOS_files_split/${DATASET}/ dir (never split?)"
        continue
    fi

    # Expected job indices from the split file names: <dataset>_job<i>.txt
    JOBS=$(ls -1 "$SPLIT_DIR" | sed -n "s/^${DATASET}_job\([0-9]*\)\.txt$/\1/p" | sort -n)
    N_EXPECTED=$(echo "$JOBS" | grep -c '[0-9]')
    if [ "$N_EXPECTED" -eq 0 ]; then
        echo "[SKIP] $DATASET — no job lists in $SPLIT_DIR"
        continue
    fi

    # EOS listing of the output dir for this dataset (may not exist yet).
    # Check both naming conventions: newer submissions use Condor_outputs/<dataset>/
    # (from -n <dataset>), older ones used Condor_outputs/H5_maker_<dataset>/.
    EOS_LIST=""
    for SUF in "$DATASET" "H5_maker_$DATASET"; do
        EOS_LIST=$(xrdfs "$EOS_ROOT" ls "$EOS_OUT/${SUF}/" 2>/dev/null || true)
        [ -n "$EOS_LIST" ] && break
    done
    if [ -z "$EOS_LIST" ]; then
        echo "  (no output files found under $EOS_OUT/<dataset>/ or $EOS_OUT/H5_maker_<dataset>/ — script falls back to FAILED)"
    fi

    OK=0; RUN=0; FAIL=0
    declare -a FAILED_JOBS=()

    for I in $JOBS; do
        H5="${DATASET}_job${I}.h5"
        if echo "$EOS_LIST" | grep -q "job${I}\.h5$"; then
            OK=$((OK+1))
        elif echo "$ACTIVE" | grep -q "${DATASET}"; then
            RUN=$((RUN+1))
        else
            FAIL=$((FAIL+1))
            FAILED_JOBS+=("$I")
        fi
    done

    G_OK=$((G_OK+OK)); G_RUN=$((G_RUN+RUN)); G_FAIL=$((G_FAIL+FAIL))

    echo "============================================"
    echo "  $DATASET"
    echo "  expected : $N_EXPECTED   ok: $OK   running: $RUN   failed: $FAIL"
    echo "============================================"
    if [ ${#FAILED_JOBS[@]} -gt 0 ]; then
        echo "  FAILED jobs: ${FAILED_JOBS[*]}"
        FAILED_DATASETS+=("$DATASET")
    fi
    echo ""
done

echo "============================================"
echo "  SUMMARY: ok=$G_OK  running=$G_RUN  failed=$G_FAIL"
echo "============================================"
echo ""

if [ "$G_FAIL" -gt 0 ]; then
    echo "The following datasets have failed jobs to re-run:"
    for d in "${FAILED_DATASETS[@]}"; do
        echo "    python3 doCondor.py -n $d -d $d --nJobs $(ls EOS_files_split/$d/*_job*.txt 2>/dev/null | wc -l) --resub --overwrite --mem 6000 -s condor_script_templates/script_temp.sh"
    done
    echo ""
    echo "NOTE: re-run only after no jobs are still active for that dataset,"
    echo "and make sure condor_jobs/$d/ still exists."
fi