#!/bin/bash
#
# test_condor_submit.sh — verify tarball and submit condor test jobs
# Run OUTSIDE singularity, from FOEProceessing/.
#
# Usage:
#   ./test_condor_submit.sh CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1
#
# Prerequisites:
#   - test_condor_preflight.sh already run (file lists + split files exist)
#   - Tarball already built inside singularity:
#       python3 doCondor.py --tar -d <dataset>
#   - Valid grid proxy (voms-proxy-init -voms cms)
#
# What it does:
#   1. Verifies tarball on EOS has all required files
#   2. Builds the job script
#   3. Submits 2 condor jobs to Condor_outputs/test_e2e/
#
# Left for manual inspection (not cleaned up):
#   - condor_jobs/test_e2e/           (job scripts + JDLs)
#

set -e

# ─── Args ───────────────────────────────────────────────────────────────
if [ $# -lt 1 ]; then
    echo "Usage: $0 <dataset>"
    echo "Example: $0 CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1"
    exit 1
fi

DATASET="$1"
TEST_NAME="test_e2e"
EOS_STORE="${FOE_EOS_STORE:-/store/group/lpctreasure}"
EOS_OUTPUT_DIR="root://cmseos.fnal.gov//${EOS_STORE}/Condor_outputs/${TEST_NAME}/"

# ─── Preflight ──────────────────────────────────────────────────────────
echo "============================================"
echo "  CONDOR PIPELINE TEST — SUBMIT"
echo "  Dataset   : $DATASET"
echo "  Output dir: $EOS_OUTPUT_DIR"
echo "============================================"
echo ""

MISSING=0
for cmd in python3 xrdcp; do
    if ! command -v $cmd &>/dev/null; then
        echo "[MISSING] $cmd"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then exit 1; fi
echo "[OK] All required commands found"

# Verify preflight outputs exist
for f in \
    "EOS_files_split/${DATASET}/${DATASET}_job0.txt" \
    "EOS_files_split/${DATASET}/${DATASET}_job1.txt" \
; do
    if [ -f "$f" ]; then
        echo "  [OK] $f"
    else
        echo "  [MISSING] $f — run test_condor_preflight.sh first"
        exit 1
    fi
done
echo ""

# ─── Step 1: Verify tarball contents ────────────────────────────────────
echo ">>> Step 1: Verifying tarball on EOS"

TARBALL="OPENDATA_CMSSW_${DATASET}.tgz"
EOS_TARBALL="root://cmseos.fnal.gov//${EOS_STORE}/Condor_inputs/${TARBALL}"

# Download tarball to inspect (it stays on EOS)
xrdcp "$EOS_TARBALL" "$TARBALL" 2>/dev/null

if [ ! -f "$TARBALL" ]; then
    echo "[FAIL] Could not download tarball from EOS"
    echo "  Did you run: python3 doCondor.py --tar -d $DATASET (inside singularity+cmsenv)?"
    exit 1
fi

echo "  Tarball: $TARBALL ($(ls -lh "$TARBALL" | awk '{print $5}'))"
echo ""

TAR_CONTENTS=$(tar -tzf "$TARBALL")

TAR_CHECK_PASSED=1
for check in \
    "CMSSW_10_6_30/src/FOEProceessing/pfnano_data_2016UL_OpenData.py" \
    "CMSSW_10_6_30/src/FOEProceessing/H5_maker_FOE.py" \
    "CMSSW_10_6_30/src/FOEProceessing/Utils.py" \
    "CMSSW_10_6_30/src/FOEProceessing/Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt" \
    "CMSSW_10_6_30/src/FOEProceessing/EOS_files_split/${DATASET}/${DATASET}_job0.txt" \
    "CMSSW_10_6_30/src/FOEProceessing/EOS_files_split/${DATASET}/${DATASET}_job1.txt" \
; do
    if echo "$TAR_CONTENTS" | grep -q "$check"; then
        echo "  [OK] $check"
    else
        echo "  [MISSING IN TARBALL] $check"
        TAR_CHECK_PASSED=0
    fi
done

for pkg in PhysicsTools/PFNano PhysicsTools/NanoAODTools; do
    if echo "$TAR_CONTENTS" | grep -q "CMSSW_10_6_30/src/$pkg/"; then
        echo "  [OK] $pkg (compiled package)"
    else
        echo "  [MISSING IN TARBALL] $pkg"
        TAR_CHECK_PASSED=0
    fi
done

echo ""
UNWANTED_FOUND=0
for pattern in "*.h5" "*.root" "*.tgz" "condor_jobs/"; do
    HITS=$(echo "$TAR_CONTENTS" | grep -c "$pattern" || true)
    if [ "$HITS" -gt 0 ]; then
        echo "  [WARNING] Found $HITS unwanted files matching '$pattern' in tarball"
        UNWANTED_FOUND=1
    fi
done
if [ "$UNWANTED_FOUND" -eq 0 ]; then
    echo "  [OK] No unwanted files (.h5, .root, .tgz, condor_jobs/) in tarball"
fi

if [ "$TAR_CHECK_PASSED" -eq 0 ]; then
    echo ""
    echo "[FAIL] Tarball is missing critical files. See above."
    rm -f "$TARBALL"
    exit 1
fi

rm -f "$TARBALL"
echo ""

# ─── Step 2: Build job script and submit ───────────────────────────────
echo ">>> Step 2: Building job script and submitting 2 condor jobs"

# NOTE: the generated job script MUST live OUTSIDE condor_jobs/<name>/.
# doCondor.py --sub --overwrite does `rm -r condor_jobs/<name>` and then
# `cp -s <script> <outdir>/my_script.sh`; if the -s script is inside the
# wiped dir it gets deleted before the copy, giving "cannot stat ... No
# such file or directory". Putting the template in condor_script_templates/
# avoids that self-clobber.
MY_SCRIPT="condor_script_templates/${TEST_NAME}_script.sh"
mkdir -p "condor_script_templates"

cat > "$MY_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash

set -ex

FOEDIR=$(ls -d FOE*[Pp]* 2>/dev/null | head -1)
cd ${FOEDIR:-FOEProcessing}/
eval `scramv1 runtime -sh`
cmsRun pfnano_data_2016UL_OpenData.py inputFiles_load=EOS_files_split/DATASET_PLACEHOLDER/DATASET_PLACEHOLDER_job${2}.txt 
python H5_maker_FOE.py -i nano_data2016.root -o DATASET_PLACEHOLDER_job${2}.h5 -j Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt 
xrdcp -f DATASET_PLACEHOLDER_job${2}.h5 ${1} 
SCRIPT_EOF

sed -i "s/DATASET_PLACEHOLDER/${DATASET}/g" "$MY_SCRIPT"
chmod +x "$MY_SCRIPT"

echo "  Created: $MY_SCRIPT"
echo "  Contents:"
cat "$MY_SCRIPT" | sed 's/^/    /'
echo ""

python3 doCondor.py \
    --njobs 2 \
    --mem 6000 \
    --overwrite \
    --sub \
    -d "$DATASET" \
    -s "$MY_SCRIPT" \
    -n "$TEST_NAME"

echo ""

# ─── Done ───────────────────────────────────────────────────────────────
echo "============================================"
echo "  CONDOR PIPELINE TEST — SUBMITTED"
echo "============================================"
echo ""
echo "  2 condor jobs submitted for dataset: $DATASET"
echo ""
echo "  Monitor with:"
echo "    condor_q"
echo ""
echo "  When jobs complete, check output at:"
echo "    xrdfs root://cmseos.fnal.gov ls /${EOS_STORE}/Condor_outputs/${TEST_NAME}/"
echo ""
echo "  Expected output files:"
echo "    ${DATASET}_job0.h5"
echo "    ${DATASET}_job1.h5"
echo ""
echo "  Files left for inspection (clean up manually):"
echo "    file_lists/${DATASET}_test.txt          — temp 2-file list"
echo "    EOS_files_split/${DATASET}/             — 2 single-file job lists"
echo "    condor_jobs/${TEST_NAME}/               — job scripts + JDLs"
echo ""
echo "  The real file_lists/${DATASET}.txt has been restored."
