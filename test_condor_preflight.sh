#!/bin/bash
#
# test_condor_preflight.sh — prepare and validate files for condor test
# Run OUTSIDE singularity, from FOEProceessing/.
#
# Usage:
#   ./test_condor_preflight.sh CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1
#
# What it does:
#   1. Creates a temp file list with the first 2 files from the dataset
#   2. Splits into 2 single-file condor jobs
#   3. Pre-flight checks (golden JSON, compiled packages, etc.)
#
# After this completes:
#   1. Enter singularity + cmsenv, run: python3 doCondor.py --tar -d <dataset>
#   2. Exit singularity, run: ./test_condor_submit.sh <dataset>
#
# Left for manual inspection (not cleaned up):
#   - file_lists/<dataset>_test.txt   (temp 2-file list)
#   - EOS_files_split/<dataset>/      (2 single-file job lists)
#

set -e

# ─── Args ───────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: $0 <dataset>"
    echo "Example: $0 CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1"
    exit 1
fi

DATASET="$1"
N_TEST_FILES=2

# ─── Banner ─────────────────────────────────────────────────────────────
echo "============================================"
echo "  CONDOR PIPELINE TEST — PREFLIGHT"
echo "  Dataset   : $DATASET"
echo "  Test files: $N_TEST_FILES"
echo "============================================"
echo ""

# ─── Step 1: Create temp file list with first N files ───────────────────
echo ">>> Step 1: Creating temp file list (${N_TEST_FILES} files)"

if [ ! -f "file_lists/${DATASET}.txt" ]; then
    echo "[FAIL] file_lists/${DATASET}.txt not found"
    exit 1
fi
TOTAL_FILES=$(wc -l < "file_lists/${DATASET}.txt")
echo "  [OK] File list found ($TOTAL_FILES files)"

TEST_FILELIST="file_lists/${DATASET}_test.txt"
head -n "$N_TEST_FILES" "file_lists/${DATASET}.txt" > "$TEST_FILELIST"
echo "  Created: $TEST_FILELIST"
cat "$TEST_FILELIST" | sed 's/^/    /'
echo ""

# ─── Step 2: Split into single-file jobs ───────────────────────────────
echo ">>> Step 2: Splitting into ${N_TEST_FILES} single-file jobs"

# Temporarily swap the file list so split_file_list.py sees only our test files.
REAL_FILELIST="file_lists/${DATASET}.txt"
BACKUP_FILELIST="file_lists/${DATASET}.txt.bak"
cp "$REAL_FILELIST" "$BACKUP_FILELIST"
cp "$TEST_FILELIST" "$REAL_FILELIST"

python3 split_file_list.py "$DATASET" --files_per_job 1

# Restore the real file list
mv "$BACKUP_FILELIST" "$REAL_FILELIST"

echo "  Split files:"
ls -1 "EOS_files_split/${DATASET}/" | sed 's/^/    /'
echo ""

# ─── Step 3: Pre-flight — verify all needed files exist ─────────────────
echo ">>> Step 3: Pre-flight file check"

REQUIRED_FILES=(
    "pfnano_data_2016UL_OpenData.py"
    "H5_maker_FOE.py"
    "Utils.py"
    "Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt"
    "EOS_files_split/${DATASET}/${DATASET}_job0.txt"
    "EOS_files_split/${DATASET}/${DATASET}_job1.txt"
)

ALL_OK=1
for f in "${REQUIRED_FILES[@]}"; do
    if [ -f "$f" ]; then
        echo "  [OK] $f"
    else
        echo "  [MISSING] $f"
        ALL_OK=0
    fi
done

# Check compiled packages exist in the CMSSW source tree
CMSSW_SRC="$(dirname "$(pwd)")"
for pkg in PhysicsTools/PFNano PhysicsTools/NanoAODTools; do
    if [ -d "$CMSSW_SRC/$pkg" ]; then
        echo "  [OK] $pkg"
    else
        echo "  [MISSING] $pkg"
        ALL_OK=0
    fi
done

# Check grid proxy
if voms-proxy-info -exists 2>/dev/null; then
    echo "  [OK] Grid proxy valid"
else
    echo "  [WARNING] No grid proxy — run: voms-proxy-init -voms cms"
fi

if [ "$ALL_OK" -eq 0 ]; then
    echo ""
    echo "[FAIL] Missing required files. Fix the above before proceeding."
    exit 1
fi

echo ""
echo "============================================"
echo "  PREFLIGHT PASSED"
echo "============================================"
echo ""
echo "  Next steps:"
echo "  1. Enter singularity + cmsenv, then run:"
echo "       python3 doCondor.py --tar -d $DATASET"
echo "  2. Exit singularity, then run:"
echo "       ./test_condor_submit.sh $DATASET"
echo ""
