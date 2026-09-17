#!/bin/bash
#
# test_e2e.sh — quick end-to-end test of the FOE pipeline.
#
# Runs cmsRun (PFNano) on a single input file with a small number of events,
# then runs H5_maker_FOE.py, and verifies the output.
#
# Usage:
#   ./test_e2e.sh                  # default 100 events
#   ./test_e2e.sh --events 500     # override event count
#   ./test_e2e.sh --cleanup        # remove intermediates on success
#
# Must be run from inside a CMSSW cmsenv shell.

set -e  # abort on first error

# ─── Config ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(pwd)"
INPUT_FILE="root://eospublic.cern.ch//eos/opendata/cms/Run2016G/BTagMu/MINIAOD/UL2016_MiniAODv2-v1/120000/024656BE-7CF3-CC49-BB03-2D71EB34F191.root"
JSON="Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt"
JSON_URL="https://opendata.cern.ch/record/14220/files/Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt"
NANO_ROOT="nano_data2016.root"
OUTPUT_H5="test_output.h5"

# Defaults
MAX_EVENTS=100
CLEANUP=0

# ─── Parse args ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --events)   MAX_EVENTS="$2"; shift 2 ;;
        --cleanup)  CLEANUP=1; shift ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# All paths are relative to the script's location — cd there first.
cd "$SCRIPT_DIR"

# ─── Helpers ────────────────────────────────────────────────────────────
pass_count=0
fail_count=0

step_pass() {
    pass_count=$((pass_count + 1))
    echo ""
    echo "========================================"
    echo "  PASS: $1"
    echo "========================================"
    echo ""
}

step_fail() {
    fail_count=$((fail_count + 1))
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  FAIL: $1"
    echo "  $2"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo ""
}

# ─── Preflight checks ──────────────────────────────────────────────────
echo "============================================"
echo "  FOE E2E TEST"
echo "  Working dir : $SCRIPT_DIR"
echo "  Input file  : $INPUT_FILE"
echo "  Max events  : $MAX_EVENTS"
echo "============================================"
echo ""

# Check we are in a cmsenv shell
if ! command -v cmsRun &>/dev/null; then
    echo "ERROR: cmsRun not found. Run 'cmsenv' first."
    exit 1
fi
echo "[OK] cmsRun found: $(which cmsRun)"

# Check we can find the PFNano config
if [ ! -f "$SCRIPT_DIR/pfnano_data_2016UL_OpenData.py" ]; then
    echo "ERROR: pfnano_data_2016UL_OpenData.py not found in $SCRIPT_DIR"
    exit 1
fi
echo "[OK] pfnano_data_2016UL_OpenData.py found"

# Check H5_maker_FOE.py exists
if [ ! -f "$SCRIPT_DIR/H5_maker_FOE.py" ]; then
    echo "ERROR: H5_maker_FOE.py not found in $SCRIPT_DIR"
    exit 1
fi
echo "[OK] H5_maker_FOE.py found"

# Check python dependencies
python -c "import h5py" 2>/dev/null || {
    echo "ERROR: python module 'h5py' not found. Install with: pip install h5py"
    exit 1
}
echo "[OK] h5py available"

echo ""

# ─── Step 0: Golden JSON ───────────────────────────────────────────────
echo ">>> Step 0: Golden JSON"
echo "Looking for $JSON in $SCRIPT_DIR ..."

if [ -f "$SCRIPT_DIR/$JSON" ]; then
    echo "  Found: $SCRIPT_DIR/$JSON ($(wc -l < "$SCRIPT_DIR/$JSON") lines)"
    step_pass "Step 0: Golden JSON already present"
else
    echo "  Not found. Attempting download from CMS Open Data..."
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$SCRIPT_DIR/$JSON" "$JSON_URL" && {
            echo "  Downloaded: $SCRIPT_DIR/$JSON ($(wc -l < "$SCRIPT_DIR/$JSON") lines)"
            step_pass "Step 0: Golden JSON downloaded"
        } || {
            step_fail "Step 0: Golden JSON download failed" \
                "Could not download from $JSON_URL
  Manual fix: download the file and place it in $SCRIPT_DIR/$JSON
  See: https://opendata.cern.ch/record/14220"
            exit 1
        }
    elif command -v curl &>/dev/null; then
        curl -sL -o "$SCRIPT_DIR/$JSON" "$JSON_URL" && {
            echo "  Downloaded: $SCRIPT_DIR/$JSON ($(wc -l < "$SCRIPT_DIR/$JSON") lines)"
            step_pass "Step 0: Golden JSON downloaded"
        } || {
            step_fail "Step 0: Golden JSON download failed" \
                "Could not download from $JSON_URL
  Manual fix: download the file and place it in $SCRIPT_DIR/$JSON
  See: https://opendata.cern.ch/record/14220"
            exit 1
        }
    else
        step_fail "Step 0: Golden JSON not found and no download tool available" \
            "Neither 'wget' nor 'curl' found.
  Manual fix: download the file and place it in $SCRIPT_DIR/$JSON
  See: https://opendata.cern.ch/record/14220"
        exit 1
    fi
fi

# ─── Step 1: cmsRun (PFNano) ──────────────────────────────────────────
echo ">>> Step 1: cmsRun PFNano ($MAX_EVENTS events)"
echo "  Input : $INPUT_FILE"
echo "  Output: $SCRIPT_DIR/$NANO_ROOT"
echo ""
echo "  This may take a few minutes on first run (file transfer from CERN EOS)..."
echo ""

if cmsRun pfnano_data_2016UL_OpenData.py \
    inputFiles="$INPUT_FILE" \
    maxEvents="$MAX_EVENTS" 2>&1; then
    echo ""
    echo "  cmsRun exited with status 0"
else
    CMSRUN_STATUS=$?
    echo ""
    step_fail "Step 1: cmsRun failed" \
        "cmsRun exited with status $CMSRUN_STATUS.
  Check the output above for CMSSW error messages.
  Common causes:
    - Input file unreachable (network / xrootd issue)
    - Missing CMSSW modules (did you run 'scram b'?)
    - Memory exceeded"
    exit 1
fi

# Verify output file exists and has content
if [ ! -f "$NANO_ROOT" ]; then
    step_fail "Step 1: cmsRun output missing" \
        "Expected $NANO_ROOT but it was not created.
  cmsRun may have crashed silently. Check the output above."
    exit 1
fi

NANO_SIZE=$(stat --printf="%s" "$NANO_ROOT" 2>/dev/null || stat -f%z "$NANO_ROOT" 2>/dev/null)
if [ "$NANO_SIZE" -lt 1000 ]; then
    step_fail "Step 1: cmsRun output suspiciously small" \
        "$NANO_ROOT is only $NANO_SIZE bytes.
  Expected at least several MB for $MAX_EVENTS events.
  The file may be corrupt or empty."
    exit 1
fi

echo "  Output size: $(ls -lh "$NANO_ROOT" | awk '{print $5}')"
step_pass "Step 1: cmsRun PFNano completed"

# ─── Step 2: H5_maker_FOE.py ──────────────────────────────────────────
echo ">>> Step 2: H5_maker_FOE.py"
echo "  Input : $NANO_ROOT"
echo "  Output: $OUTPUT_H5"
echo "  JSON  : $JSON"
echo ""

if python H5_maker_FOE.py \
    -i "$NANO_ROOT" \
    -o "$OUTPUT_H5" \
    -j "$JSON" \
    -n "$MAX_EVENTS" 2>&1; then
    echo ""
    echo "  H5_maker_FOE.py exited with status 0"
else
    H5_STATUS=$?
    echo ""
    step_fail "Step 2: H5_maker_FOE.py failed" \
        "H5_maker_FOE.py exited with status $H5_STATUS.
  Check the output above for Python tracebacks.
  Common causes:
    - Golden JSON missing or corrupt (Step 0)
    - nano_data2016.root is empty or corrupt (Step 1)
    - Missing python modules (h5py, numpy, ROOT)"
    exit 1
fi

# Verify output file exists and has content
if [ ! -f "$OUTPUT_H5" ]; then
    step_fail "Step 2: H5 output missing" \
        "Expected $OUTPUT_H5 but it was not created.
  H5_maker_FOE.py may have crashed silently."
    exit 1
fi

H5_SIZE=$(stat --printf="%s" "$OUTPUT_H5" 2>/dev/null || stat -f%z "$OUTPUT_H5" 2>/dev/null)
if [ "$H5_SIZE" -lt 100 ]; then
    step_fail "Step 2: H5 output suspiciously small" \
        "$OUTPUT_H5 is only $H5_SIZE bytes.
  Expected at least several KB for $MAX_EVENTS events."
    exit 1
fi

echo "  Output size: $(ls -lh "$OUTPUT_H5" | awk '{print $5}')"
step_pass "Step 2: H5_maker_FOE completed"

# ─── Step 3: Verify H5 contents ────────────────────────────────────────
echo ">>> Step 3: Verify H5 contents"
echo ""

VERIFY_RESULT=$(python3 -c "
import h5py, sys
try:
    f = h5py.File('$OUTPUT_H5', 'r')
    keys = sorted(f.keys())
    print('Keys:', keys)

    # Check expected keys exist
    expected = ['PFCands', 'event_info']
    missing = [k for k in expected if k not in keys]
    if missing:
        print('ERROR: missing keys:', missing)
        f.close()
        sys.exit(1)

    n_events = f['event_info'].shape[0]
    n_pfcands = f['PFCands'].shape[0]
    pfcands_shape = f['PFCands'].shape

    print('event_info: %d events, shape=%s' % (n_events, str(f['event_info'].shape)))
    print('PFCands:    %d events, shape=%s' % (n_pfcands, str(pfcands_shape)))

    if n_events == 0:
        print('ERROR: zero events in output')
        f.close()
        sys.exit(1)

    if n_events != n_pfcands:
        print('ERROR: event_info (%d) and PFCands (%d) have different event counts' % (n_events, n_pfcands))
        f.close()
        sys.exit(1)

    # Check PFCands has expected feature dimension (11)
    if len(pfcands_shape) != 3 or pfcands_shape[2] != 11:
        print('ERROR: PFCands shape is %s, expected (N, 500, 11)' % str(pfcands_shape))
        f.close()
        sys.exit(1)

    f.close()
    print('All checks passed.')
    sys.exit(0)
except Exception as e:
    print('ERROR:', e)
    sys.exit(1)
" 2>&1)

echo "$VERIFY_RESULT"

if echo "$VERIFY_RESULT" | grep -q "All checks passed"; then
    step_pass "Step 3: H5 contents verified"
else
    step_fail "Step 3: H5 verification failed" \
        "The H5 file exists but has unexpected contents.
  Output above shows what went wrong."
    exit 1
fi

# ─── Summary ────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo "  E2E TEST SUMMARY"
echo "  Passed: $pass_count / $((pass_count + fail_count))"
echo "============================================"

if [ "$fail_count" -eq 0 ]; then
    echo "  ALL PASSED"
    echo ""
    echo "  Test files produced:"
    echo "    $SCRIPT_DIR/$NANO_ROOT  (PFNano ROOT output)"
    echo "    $SCRIPT_DIR/$OUTPUT_H5  (H5 output)"
    if [ "$CLEANUP" -eq 1 ]; then
        echo ""
        echo "  Cleaning up test artifacts..."
        rm -f "$SCRIPT_DIR/$NANO_ROOT" "$SCRIPT_DIR/$OUTPUT_H5"
        echo "  Done."
    else
        echo ""
        echo "  Run with --cleanup to remove test artifacts."
    fi
    exit 0
else
    echo "  $fail_count STEP(S) FAILED"
    exit 1
fi
