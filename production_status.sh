#!/bin/bash
#
# production_status.sh — one-glance report of where you are in the FOE condor
# production pipeline for every dataset in file_lists/. Run OUTSIDE singularity
# from the FOEProceessing working dir, on a node with EOS + condor access.
#
# For each dataset it inspects the verifiable artifacts of the 4 pipeline steps:
#   split   -> EOS_files_split/<dataset>/<dataset>_job*.txt   (job count vs expected)
#   tar     -> OPENDATA_CMSSW_<dataset>.tgz on EOS Condor_inputs
#   submit  -> .jdl scripts in condor_jobs/<dataset>/          (and condor_q for live jobs)
#   output  -> <dataset>_job<i>.h5 on EOS Condor_outputs/<dataset>/
#
# Overall status legend:
#   OK       all expected .h5 outputs are on EOS
#   RUN      submitted and jobs still in the condor queue
#   RUN!     in queue but some jobs are held / idle for hours / running way
#            past precedent / not burning CPU -> likely stuck, inspect
#   !!       was submitted but missing .h5 and no jobs queued -> inspect/resub
#   ..       split done, tar optional, but never submitted (no .jdl)
#   --       never split
#
# In-queue health scan (RUN datasets only) - are the jobs actually working?
#   HELD       job not executing at all (condor -held; often the Docker 2048 MB
#              memory cap) -> definitely stuck
#   IDLE-STALE idle longer than FOE_STATUS_IDLE_MAX (default 2 h) -> no slot/wedged
#   LONG-RUN   running longer than FOE_STATUS_RUN_MAX (default 40 h; the longest
#              known-good job ran 39 h) -> way past precedent, check
#   LOW-CPU    running past FOE_STATUS_GRACE (default 30 min) but average user-CPU
#              share < FOE_STATUS_CPU_MIN (default 5%) -> suspected hung/blocked
#
# Exit codes: 0 = all done, 1 = something needs attention, 2 = pending/staged only.

EOS_ROOT="root://cmseos.fnal.gov"
EOS_BASE="${FOE_EOS_STORE:-/store/group/lpctreasure}"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# ─── helpers: tolerant EOS/queue queries (never hang the report) ─────────
eos_ls() { # eos_ls <dir>  -> prints basenames or nothing
    command xrdfs "$EOS_ROOT" ls "$1" 2>/dev/null | sed 's#.*/##'
}

# ─── gather dataset names once ───────────────────────────────────────────
MAPFILE=()
for lst in file_lists/*.txt; do
    [ -e "$lst" ] || continue
    base=$(basename "$lst" .txt)
    [[ "$base" == *_test* ]] && continue       # ignore legacy test lists
    MAPFILE+=("$base")
done

echo "======================================================================"
echo " FOE PRODUCTION STATUS  ($(date '+%F %T'))"
echo " datasets: ${#MAPFILE[@]}   (from file_lists/*.txt, _test excluded)"
echo "======================================================================"

if [ ${#MAPFILE[@]} -eq 0 ]; then
    echo "No dataset file lists found under file_lists/."
    exit 0
fi

# Snapshot: whole queue once + tarballs on EOS once
QUEUE=$(command condor_q 2>/dev/null || true)
TARS=$(eos_ls "$EOS_BASE/Condor_inputs")

# ─── stuck/slow watch thresholds (env-overridable) ──────────────────────
IDLE_MAX=${FOE_STATUS_IDLE_MAX:-7200}      # idle > 2 h        -> flagged
RUN_MAX=${FOE_STATUS_RUN_MAX:-144000}      # running > 40 h    -> flagged (longest good job was 39 h)
CPU_MIN=${FOE_STATUS_CPU_MIN:-0.05}        # avg user-CPU share < 5% -> suspect hung
GRACE=${FOE_STATUS_GRACE:-1800}            # ignore CPU check during first 30 min
fmt_age() { local s=$1; printf "%dh%02dm" $((s/3600)) $(((s%3600)/60)); }

# Full queue snapshot with the per-job classads we need (once).
# Fields: cluster|proc|status|entered|started|userCPU|now|cmd|args|holdReason
QDATA=$(command condor_q \
    -format '%d|' ClusterId -format '%d|' ProcId -format '%d|' JobStatus \
    -format '%d|' EnteredCurrentStatus -format '%d|' JobStartDate \
    -format '%.2f|' RemoteUserCpu -format '%d|' CurrentTime \
    -format '|%s' Cmd -format '|%s' Args \
    -format '|%s\n' HoldReason 2>/dev/null || true)

declare -a NEEDS=() NEEDS_JOBS=() STAGED=() RUNNING=() DONE_D=() PENDING=() STUCK=() STUCK_TXT=()

printf "%-58s %6s %5s | %-4s %3s %5s %8s | %s\n" \
       "DATASET" "files" "jobs" "spLt" "tar" "subm" "h5" "STATUS"
printf '%*s\n' 118 '' | tr ' ' '-'

for D in "${MAPFILE[@]}"; do
    N_FILES=$(wc -l < "file_lists/$D.txt" | tr -d ' ')
    # Job-count ESTIMATE, only used for datasets that have not been split yet:
    # ceil(files / fpe) with 3 mc / 8 data per job. Once split, the real count
    # below (number of EOS_files_split/<D>/<D>_job*.txt) overrides this, so the
    # report matches the pipeline (which now typically runs --files_per_job 1).
    FPE=$([[ "$D" == CMS_mc_* ]] && echo 3 || echo 8)
    N_EST=$(( (N_FILES + FPE - 1) / FPE ))
    N_JOBS=$N_EST

    # split status
    SPLIT_DIR="EOS_files_split/$D"
    N_SPLIT=0
    SPLIT_JOBS=""
    SPLIT_STAT="${DIM}--$NC"
    if [ -d "$SPLIT_DIR" ]; then
        N_SPLIT=$(ls -1 "$SPLIT_DIR" 2>/dev/null | grep -c "^${D}_job[0-9]*\.txt\$" || true)
        SPLIT_JOBS=$(ls -1 "$SPLIT_DIR" 2>/dev/null \
                     | sed -n "s/^${D}_job\([0-9]*\)\.txt\$/\1/p" | sort -n)
        # The split lists are the source of truth for the real job count (they
        # are exactly what gets shipped in the tarball and submitted); only a
        # never-split dataset falls back to the fpe estimate above.
        [ "$N_SPLIT" -gt 0 ] && N_JOBS=$N_SPLIT
        SPLIT_STAT="${GREEN}${N_SPLIT}$NC"
    fi

    # tar on EOS (dataset-specific tarball)
    TAR_STAT="${DIM}--$NC"
    if echo "$TARS" | grep -q "^OPENDATA_CMSSW_${D}\.tgz$"; then
        TAR_STAT="${GREEN}yes$NC"
    fi

    # submitted: any .jdl in condor_jobs/<D>/
    SUBM_STAT="${DIM}--$NC"; N_JDL=0
    if [ -d "condor_jobs/$D" ]; then
        N_JDL=$(ls -1 "condor_jobs/$D" 2>/dev/null | grep -c "\.jdl\$" || true)
        [ "$N_JDL" -gt 0 ] && SUBM_STAT="${YELLOW}${N_JDL}$NC"
    fi

    # outputs on EOS
    H5_LIST=$(eos_ls "$EOS_BASE/Condor_outputs/$D")
    H5=$(echo "$H5_LIST" | grep -c "job[0-9]*\.h5\$" || true)
    if [ "$H5" -gt 0 ]; then H5_STAT="${GREEN}$H5/$N_JOBS$NC"
    else                    H5_STAT="${DIM}-$NC"; fi

    # in condor queue?
    INQ=0; echo "$QUEUE" | grep -q "$D" && INQ=1

    # ── in-queue health scan: are the jobs actually doing something? ───────
    st_held=0; st_idle=0; st_long=0; st_low=0
    TXT_HELD=""; TXT_IDLE=""; TXT_LONG=""; TXT_LOW=""
    if [ "$INQ" -eq 1 ]; then
        while IFS='|' read -r _cl _pr _st _ec _js _cpu _now _cmd _args _hr; do
            _js=${_js:-0}; _ec=${_ec:-0}; _cpu=${_cpu:-0}
            ji=$(basename "${_cmd}" 2>/dev/null | sed -n 's/^.*_job\([0-9]*\)\..*$/\1/p')
            [ -n "$ji" ] || ji=$(basename "${_cmd}" 2>/dev/null)   # e.g. old-era my_script.sh
            [ -n "$ji" ] || ji="?"
            case "$_st" in
                5) # HELD -> not executing at all (often Docker memory cap)
                   st_held=$((st_held+1))
                   TXT_HELD+=" job${ji}(cl${_cl})['${_hr:0:110}']"
                   ;;
                1) # IDLE too long -> never acquired a slot / wedged
                   if [ $((_now-_ec)) -gt "$IDLE_MAX" ]; then
                       st_idle=$((st_idle+1))
                       TXT_IDLE+=" job${ji}(cl${_cl}) idle $(fmt_age $((_now-_ec)))"
                   fi
                   ;;
                2) # RUNNING: flag if way past precedent or ~no CPU ticks
                   _ra=$((_now-_js))
                   [ "$_ra" -lt 0 ] && _ra=0
                   if [ "$_ra" -gt "$RUN_MAX" ]; then
                       st_long=$((st_long+1)); TXT_LONG+=" job${ji}(cl${_cl}) up $(fmt_age $_ra)"
                   fi
                   if [ "$(awk -v a="$_ra" -v g="$GRACE" -v m="$CPU_MIN" -v c="$_cpu" \
                        'BEGIN{print (a>g && a>0 && c/a<m)?1:0}')" = "1" ]; then
                       _pct=$(awk -v a="$_ra" -v c="$_cpu" 'BEGIN{printf "%.1f", (a>0?c/a*100:0)}')
                       st_low=$((st_low+1)); TXT_LOW+=" job${ji}(cl${_cl}) CPU~${_pct}%"
                   fi
                   ;;
            esac
        done < <(printf '%s\n' "$QDATA" | grep -F -- "$D")
    fi

    # ── overall status ──────────────────────────────────────────────────
    if [ "$H5" -eq "$N_JOBS" ]; then
        ST="${GREEN}OK$NC";          STATUS=DONE;   DONE_D+=("$D")
    elif [ "$INQ" -eq 1 ]; then
        ST="${YELLOW}RUN$NC";        STATUS=RUNNING; RUNNING+=("$D")
        if [ $((st_held+st_idle+st_long+st_low)) -gt 0 ]; then
            ST="${YELLOW}RUN$NC${RED}!$NC"
            BLK=""
            [ "$st_held" -gt $((0)) ] && BLK="${BLK}      HELD       :${TXT_HELD}"$'\n'
            [ "$st_idle" -gt $((0)) ] && BLK="${BLK}      IDLE-STALE :${TXT_IDLE}"$'\n'
            [ "$st_long" -gt $((0)) ] && BLK="${BLK}      LONG-RUN   :${TXT_LONG}"$'\n'
            [ "$st_low"  -gt $((0)) ] && BLK="${BLK}      LOW-CPU    :${TXT_LOW}"$'\n'
            STUCK+=("$D"); STUCK_TXT+=("$D"$'\n'"$(printf '%b' "$BLK")")
        fi
    elif [ "$N_JDL" -gt 0 ]; then
        ST="${RED}!!$NC";            STATUS=FAIL;   NEEDS+=("$D")
        # jobs that lack their .h5 and are not queued -> inspect/resub
        FJ=()
        for ji in $SPLIT_JOBS; do
            if ! echo "$H5_LIST" | grep -q "${D}_job${ji}\.h5\$"; then
                FJ+=("$ji")
            fi
        done
        NEEDS_JOBS+=("${FJ[*]}")
    elif [ "$N_SPLIT" -gt 0 ]; then
        ST="${CYAN}..$NC";           STATUS=STAGED; STAGED+=("$D")
    else
        ST="${DIM}--$NC";            STATUS=PENDING; PENDING+=("$D")
    fi

    printf "%-58s %6s %5s | %-4s %3s %5s %8s | %s\n" \
           "$D" "$N_FILES" "$N_JOBS" "$SPLIT_STAT" "$TAR_STAT" "$SUBM_STAT" "$H5_STAT" "$ST"
done

printf '%*s\n' 118 '' | tr ' ' '-'

echo "Legend  spLt=split(jobs)  tar=yes on EOS  subm=#jdl  h5=ok/expected"
echo "        ${GREEN}OK$NC done  ${YELLOW}RUN$NC queued  ${YELLOW}RUN${RED}!$NC queued but stuck/suspect  ${RED}!!$NC needs attention  ${CYAN}..$NC staged  ${DIM}--$NC pending"

echo
echo "${BOLD}Summary:${NC}"
echo "  ${GREEN}OK${NC}    : ${#DONE_D[@]} done"
echo "  ${YELLOW}RUN${NC}   : ${#RUNNING[@]} in flight"
echo "  ${YELLOW}RUN${RED}!${NC}  : ${#STUCK[@]} in flight but stuck/suspect"
echo "  ${RED}!!${NC}    : ${#NEEDS[@]} need a human"
echo "  ${CYAN}..${NC}    : ${#STAGED[@]} split, not submitted"
echo "  --    : ${#PENDING[@]} not started"

if [ ${#STUCK[@]} -gt 0 ]; then
    echo
    echo "${BOLD}In queue but STUCK/SUSPECT (${YELLOW}RUN${RED}!$NC) - jobs are not producing .h5, check first:${NC}"
    for e in "${STUCK_TXT[@]}"; do
        while IFS= read -r ln; do [ -n "$ln" ] && echo "    $ln"; done <<< "$e"
    done
    echo
    echo "    Inspect a specific job:   cat condor_jobs/<D>/<D>_job<N>.sh.jdl.stdout"
    echo "    Kill + resub a dataset:   python3 doCondor.py -n <D> -d <D> --nJobs <N> --resub --overwrite --mem 6000 -s condor_script_templates/script_temp.sh"
fi

if [ ${#RUNNING[@]} -gt 0 ]; then
    echo
    echo "${BOLD}In flight (in condor_q):${NC}"
    printf '    %s\n' "${RUNNING[@]}"
fi
if [ ${#NEEDS[@]} -gt 0 ]; then
    echo
    echo "${BOLD}Needs a human (missing .h5, nothing queued) - inspect logs then resub:${NC}"
    for idx in "${!NEEDS[@]}"; do
        d="${NEEDS[$idx]}"
        jobs="${NEEDS_JOBS[$idx]:-unknown}"
        n=$(ls EOS_files_split/$d/*_job*.txt 2>/dev/null | wc -l)
        echo "    $d"
        echo "      job(s) to look at / resubmit: ${jobs}"
        echo "      python3 doCondor.py -n $d -d $d --nJobs $n --resub --overwrite --mem 6000 -s condor_script_templates/script_temp.sh"
    done
fi
if [ ${#STAGED[@]} -gt 0 ]; then
    echo
    echo "${BOLD}Staged (split/tar ready, not submitted yet):${NC} ${STAGED[*]}"
fi
if [ ${#PENDING[@]} -gt 0 ]; then
    echo
    echo "${BOLD}Pending (not split yet):${NC} ${PENDING[*]}"
fi

echo
if [ ${#NEEDS[@]} -gt 0 ] || [ ${#STUCK[@]} -gt 0 ]; then exit 1; fi
if [ ${#RUNNING[@]} -gt 0 ] || [ ${#STAGED[@]} -gt 0 ] || [ ${#PENDING[@]} -gt 0 ]; then exit 2; fi
exit 0