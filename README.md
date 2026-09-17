# Fermi Open Events Processing

Code to process the CMS Open Data sample used to make the Fermi Open Events (FOE) sample.

At a high level we start with CMS data at the **MINIAOD** tier, convert it to a
**NANOAOD**-like format that additionally stores the Particle Flow candidates
(constituents) of every jet using [PFNano](https://opendata.cern.ch/record/12504),
then run `H5_maker_FOE.py` — which uses
[NanoAODTools](https://opendata.cern.ch/record/12507) to apply basic selections
and write the jets to HDF5 (`.h5`).

There are three ways to run, in increasing order of scale:

| Tier | What it does | Time |
|------|--------------|------|
| 1. Single file | `cmsRun` + `H5_maker_FOE.py` on one MINIAOD file | minutes |
| 2. End-to-end test | `test_e2e.sh` (local) or the 2-file condor test | ~minutes / ~hours |
| 3. Production | split → tar → submit → verify over whole datasets on condor | days, 50+ datasets |

---

## Quickstart — from a fresh checkout you run production

This is the whole recipe for "clone the code somewhere and drive it." It
assumes you are on a CMS LPC login node (e.g. `cmslpc-el9.fnal.gov`) with
`/cvmfs`, EOS, and the condor farm available.

### 1. One-time: scaffold a 2016 CMSSW release

The analysis code must live inside a `CMSSW_10_6_30/src` area (it needs the
release's runtime environment; `cmsrel` creates the symlink farm).

```bash
source /cvmfs/cms.cern.ch/cmsset_default.sh
export SCRAM_ARCH=slc7_amd64_gcc700
cmssw-el7 --cmd-to-run cmsrel CMSSW_10_6_30   # LPC hosts: use cmssw-el7 wrapper
# (or, outside LPC: cmsrel CMSSW_10_6_30)
cd CMSSW_10_6_30/src
```

Clone this repo as **`FOEProceessing`** (the double-c name is required — the
condor templates auto-detect it via a `FOE*[Pp]*` glob), then add the two
dependencies and build:

```bash
git clone <this-repo> FOEProceessing
git clone --depth 1 git@github.com:cms-opendata-analyses/PFNanoProducerTool.git PhysicsTools/PFNano
git clone --depth 1 https://github.com/cms-nanoAOD/nanoAOD-tools.git PhysicsTools/NanoAODTools
cd FOEProceessing
cmsenv
scram b -j4
```

`scram b` rebuilds against the mounted cvmfs release. The analysis dir is
intentionally named `FOEProceessing` (double-c, inherited from upstream) — do
**not** rename it unless you also update `condor_script_templates/`.

### 2. One-time: proxy

Any condor use needs a valid grid proxy:

```bash
voms-proxy-init -voms cms -valid 168:00
voms-proxy-info -all
```

Proxies expire — re-run if condor submission complains about a missing/expired
`X509_USER_PROXY`.

### 3. One-time: EOS store location

Everything on EOS lives under `Condor_inputs/` (tarballs) and
`Condor_outputs/<DATASET>/` (`.h5` files). The store defaults to the group's
shared **`/store/group/lpctreasure`** on `cmseos.fnal.gov`. Point it elsewhere
if you're not in the group or want a scratch area:

```bash
export FOE_EOS_STORE=/store/group/lpctreasure    # default; or your own:
# export FOE_EOS_STORE=/store/user/<USER>
```

Export it the same way in every shell that runs `doCondor.py`
(`--tar`, `--sub`, `--resub`) — all tools honor it. Check it with:

```bash
xrdfs root://cmseos.fnal.gov ls /store/group/lpctreasure   # if using default
```

### 4. Bootstrap the dataset file lists

```bash
python3 fetch_file_lists.py --all      # 34 CMS 2016 UL datasets -> file_lists/*.txt
```

### 5. Run production (per dataset, IN THIS ORDER)

```bash
# OUTSIDE singularity. Split the dataset's file list into per-job lists.
# 1 file/job is the verified production setting (no condor 2048 MB memory
# holds, short per-job wall time). Default if you omit it: 8 files/job (data),
# 3 files/job (MC).
python3 split_file_list.py <DATASET> --files_per_job 1

# INSIDE singularity + cmsenv (build/upload the dataset tarball).
# NOTE: must run AFTER splitting so the split lists ship in the tarball.
# Only this dataset's files go in; uploads OPENDATA_CMSSW_<DATASET>.tgz.
python3 doCondor.py --tar -d <DATASET>
#   singularity command on LPC:
#   cmssw-el7 -p --bind $(readlink $HOME) --bind $(readlink -f ${HOME}/nobackup/) \
#       --bind /uscms_data --bind /cvmfs --bind /uscmst1b_scratch -- /bin/bash -l
#   then: cd <release>/src/FOEProceessing && cmsenv && python3 doCondor.py --tar -d <DATASET>

# OUTSIDE singularity (but before submit): confirm the uploaded tarball ships
# N+1 split entries (N jobs + the split dir itself). Skip this and a
# stale/re-split dataset dies on the worker with "RuntimeError: Bad filename".
xrdcp root://cmseos.fnal.gov//store/group/lpctreasure/Condor_inputs/OPENDATA_CMSSW_<DATASET>.tgz /tmp/t.tgz
tar -tzf /tmp/t.tgz | grep -c EOS_files_split/<DATASET>

# OUTSIDE singularity. Submit all jobs. (--mem 6000 is already the default.)
python3 submit_condor_jobs.py <DATASET> --submit --files_per_job 1

# Monitor / verify / resubmit
./production_status.sh
./verify_condor_jobs.sh <DATASET>
python3 doCondor.py -n <DATASET> -d <DATASET> --njobs <N> --resub --overwrite --mem 6000 \
    -s condor_script_templates/script_temp.sh
```

Example with a real dataset (BTagCSV 2016G, 1105 files):

```bash
python3 split_file_list.py CMS_Run2016G_BTagCSV_MINIAOD_UL2016_MiniAODv2-v1 --files_per_job 1
# <inside singularity+cmsenv>
python3 doCondor.py --tar -d CMS_Run2016G_BTagCSV_MINIAOD_UL2016_MiniAODv2-v1
# <outside>
python3 submit_condor_jobs.py CMS_Run2016G_BTagCSV_MINIAOD_UL2016_MiniAODv2-v1 --submit --files_per_job 1
```

### The 4 rules that make it work (read these once)

1. **Order matters**: split → tar → submit. The tarball ships whatever split
   files existed at tar time. Re-split a dataset → **re-tar** it or jobs die
   with `RuntimeError: Bad filename`.
2. **Always pass `-d <DATASET>`** on `--tar`, `--submit`, and `--resub`. Without
   it workers fetch the generic `OPENDATA_CMSSW.tgz` and fail.
3. **Always pass `--mem 6000`** (or higher) on `doCondor.py` runs. The default
   requests no memory and condor's 2048 MB cap holds/kills large jobs.
4. **`condor_script_templates/script_temp.sh` is shared and dataset-specific**:
   regenerate it with `./makeMyScripts.sh <DATASET> [--type data|mc]` before any
   resub, or the workers will run the *previous* dataset's paths.

Common one-off gotchas: run `condor_submit` and `xrdfs` only on the host
(not inside singularity); the `.jdl` (not the `.sh`) is what's submitted and
`doCondor.py` handles that internally; use `--njobs` (lowercase n). Known tool
quirks (don't rely on them): `--job_list` matches by substring — use `--resub`;
`--dry-run` does **not** gate the submit path; `--tarexclude` in `doCondor.py`
is dead code. Condor holding jobs with `memory limit of 2048 Mb` means `--mem
6000` was dropped from a `doCondor.py` call.

---

## Tier 1 — Run a single file (sanity check, ~minutes)

The golden JSON `Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt`
— the json file listing the 2016 data runs validated by CMS to be of good
quality — lives in this repo. Run the two processing steps on one MINIAOD file:

```bash
# Step 1: MINIAOD -> PFNano (NANOAOD + PFCandidates)
cmsRun pfnano_data_2016UL_OpenData.py \
    inputFiles=root://eospublic.cern.ch//eos/opendata/cms/Run2016G/JetHT/MINIAOD/UL2016_MiniAODv2-v2/130000/35017A26-8C9D-204D-92B6-3ABFBBD4ADF3.root

# Step 2: PFNano -> HDF5 (data version requires the golden JSON)
python H5_maker_FOE.py -i nano_data2016.root -o outfile.h5 \
    --sample_type data \
    -j Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt
```

A cert file is **not** necessary when running on MC — the golden JSON
certifies only real data-taking runs; simulated samples have no such
certification. For MC use the `pfnano_mc_2016UL_OpenData.py` config and no
`-j`:

```bash
cmsRun pfnano_mc_2016UL_OpenData.py inputFiles=root://.../<mc_file>.root
python H5_maker_FOE.py -i nano_mc2016post.root -o outfile.h5 --sample_type MC
```

Two configs are provided: `pfnano_data_2016UL_OpenData.py` and
`pfnano_mc_2016UL_OpenData.py`. Each also accepts `inputFiles_load=<list.txt>`
to run over a set of files. Note `inputFiles=` runs every file (or all files in
the list); `maxEvents=N` limits to N events for quick tests.

---

## Tier 2 — End-to-end tests

### 2a. Fully local, no condor (~minutes)

`test_e2e.sh` runs the entire pipeline in the current shell: verifies the
golden JSON (downloads it if missing), runs `cmsRun` on **one** input file at
100 events, runs `H5_maker_FOE.py`, and validates the `.h5` structure.

```bash
# inside cmsenv
./test_e2e.sh                 # default 100 events
./test_e2e.sh --events 500    # override
./test_e2e.sh --cleanup       # remove intermediate files on success
```

### 2b. Two-file condor test (validates the real machinery)

This exercises the actual production path (tarball + condor submission) with 2
single-file jobs. Requires a condor node, a proxy, and an existing file list
(see Tier 3, step 1).

```bash
# Step 1 (outside singularity): build a 2-file test list + splits + preflight
./test_condor_preflight.sh CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1

# Step 2 (inside singularity + cmsenv): build + upload the dataset tarball
python3 doCondor.py --tar -d CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1

# Step 3 (outside singularity): verify tarball + submit 2 jobs
./test_condor_submit.sh CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1
```

Output `.h5` files land in `Condor_outputs/test_e2e/` on EOS.

---

## Tier 3 — Production

Production runs every dataset through a fixed four-stage pipeline. The steps
must be run **in order**: the tarball (step 3) must be built *after* splitting
(step 2) so the job file lists ship inside it, and `-d <dataset>` must be
passed on both tar and submit so workers fetch the *dataset-specific* tarball.

### Step 0. Prepare the file lists

Fetch the full MINIAOD file list for each dataset from the CERN Open Data
portal (writes `file_lists/<dataset>.txt`):

```bash
python3 fetch_file_lists.py --all        # all 34 CMS 2016 UL datasets
# or a subset by record id:
python3 fetch_file_lists.py 30508 30541  # JetHT 2016G + 2016H
```

Dataset names follow `CMS_<RunPeriod>_<Name>_MINIAOD_<UL2016_...>.txt` and are
derived automatically from the portal's EOS paths.

### Step 1. Split files into per-job lists (outside singularity)

```bash
# 1 file/job is the verified production setting (no 2048 MB memory holds,
# shorter per-job wall times). Defaults: 8 files/job (data), 3 (MC).
python3 split_file_list.py <DATASET> --files_per_job 1
python3 split_file_list.py <DATASET>             # data (default 8 files/job)
python3 split_file_list.py CMS_mc_<DATASET>      # MC (default 3 files/job)
python3 split_file_list.py <DATASET> --files_per_job N   # any other override
```

Writes `EOS_files_split/<DATASET>/<DATASET>_job{i}.txt` for
`ceil(files/N)` jobs — that file count is what the dashboard uses as the
expected job count (it is the same thing that ships in the tarball).

### Step 2. Build & upload the dataset tarball (inside singularity + cmsenv)

```bash
# e.g. on an LPC node:
cmssw-el7 -p --bind $(readlink $HOME) --bind $(readlink -f ${HOME}/nobackup/) \
    --bind /uscms_data --bind /cvmfs --bind /uscmst1b_scratch -- /bin/bash -l
cd CMSSW_10_6_30/src/FOEProceessing
cmsenv
python3 doCondor.py --tar -d <DATASET>
```

Ships only the source subtrees the worker needs (`FOEProceessing` + the
compiled `PhysicsTools` packages) and, with `-d`, **only this dataset's** split
lists and file list. Uploads `OPENDATA_CMSSW_<DATASET>.tgz` to
`Condor_inputs/` on EOS.

### Step 3. Submit (outside singularity)

```bash
python3 submit_condor_jobs.py <DATASET> --submit --files_per_job 1
```

Builds the job script (data vs MC detected from the name), regenerates the
`.jdl` files, and submits all jobs. Outputs:
`Condor_outputs/<DATASET>/<DATASET>_job{i}.h5`. The `--files_per_job` value
must match the split you made in Step 1.

> `submit_condor_jobs.py` builds the per-dataset job scripts and, with
> `--submit`, submits them; it prints the same split → tar → submit order
> above, which must be followed (tar must still run inside singularity).

### Step 4. Monitor, verify, recover

```bash
condor_q

# One-glance chart over every dataset in file_lists/:
./production_status.sh

# Per-dataset detail (OK / RUNNING / FAILED):
./verify_condor_jobs.sh                 # all split datasets
./verify_condor_jobs.sh <DATASET>       # one dataset
```

`production_status.sh` gives a per-dataset row: split vs expected jobs, tarball
present?, # `.jdl` submitted, `.h5` done/total, and an overall state
(`OK` / `RUN` / `!!` needs attention / `..` staged / `--` pending). For any
dataset needing attention it prints the *specific* missing job indices and the
exact re-submit command.

Re-run failed jobs (only after none are still queued for that dataset):

```bash
python3 doCondor.py -n <DATASET> -d <DATASET> --njobs <N> --resub --overwrite \
    -s condor_script_templates/script_temp.sh
```

`--resub` regenerates the `.jdl` and submits only the jobs whose `.h5` is
missing on EOS. Job logs (for inspecting failures) are in
`condor_jobs/<DATASET>/<DATASET>_job<X>.sh.jdl.stdout`.

---

## Re-running a whole dataset cleanly (from scratch)

The recipe above is enough for a **new** dataset. If instead you must re-run a
dataset that has already been processed (code or pipeline changed, you want
verifiable fresh outputs), first delete every leftover of the earlier run:
stale `.h5` files on EOS share job indices with the new run and pollute the
verification counts, and a stale tarball/split makes workers die with
`RuntimeError: Bad filename`. The order below is the order that works.

This is the full cut-and-paste sequence. Set `DATASET` once at the top; it is
set again inside the container because the shell environment does not survive
the singularity boundary.

```bash
# ═════════════ OUTSIDE singularity ════════════════
# 0) Get to the work area (adjust if you keep the repo elsewhere).
cd /uscms/home/jen_a/nobackup/amsc-treasure/CMSSW_10_6_30/src/FOEProceessing
#    Inside the container the same dir is mounted at:
#    /uscms_data/d2/jen_a/amsc-treasure/CMSSW_10_6_30/src/FOEProceessing

# 1) Valid proxy before any condor/EOS work (re-run if it expired).
voms-proxy-init --valid 192:00 -voms cms
voms-proxy-info -all

# 2) Dataset to redo, e.g. the BTagMu 2016G example:
DATASET=CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1

# 3) Remove the previous run's artifacts.
#    a. stale .h5 outputs on EOS (old job indices would pollute verify)
rm -f /eos/uscms/store/group/lpctreasure/Condor_outputs/$DATASET/${DATASET}_job*
#    b. old tarball on EOS + any leftover generic/junk entries in Condor_inputs
rm -f /eos/uscms/store/group/lpctreasure/Condor_inputs/OPENDATA_CMSSW_${DATASET}.tgz
rm -f /eos/uscms/store/group/lpctreasure/Condor_inputs/OPENDATA_CMSSW.tgz
rm -f /eos/uscms/store/group/lpctreasure/Condor_inputs/foo.txt
#    c. local per-job debris + the shared job-script template (recreated on submit)
rm -rf condor_jobs/$DATASET/*
rm -rf EOS_files_split/$DATASET/${DATASET}_job*
rm -f  condor_script_templates/script_temp.sh

# 4) Re-split (1 file/job = verified production setting).
python3 split_file_list.py $DATASET --files_per_job 1

# ═════════════ ENTER singularity ══════════════════
# (commands from here until 'exit' run INSIDE the container)
cmssw-el7 -p --bind $(readlink $HOME) --bind $(readlink -f ${HOME}/nobackup/) \
    --bind /uscms_data --bind /cvmfs --bind /uscmst1b_scratch -- /bin/bash -l

# 5) Build + upload the dataset tarball (tar AFTER split so the per-job
#    lists ship inside). cd to the container path, cmsenv, tar for THIS
#    dataset only with -d.
DATASET=CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1   # env does not cross the boundary
cd /uscms_data/d2/jen_a/amsc-treasure/CMSSW_10_6_30/src/FOEProceessing
cmsenv
python3 doCondor.py --tar -d $DATASET

# ═════════════ LEAVE singularity ══════════════════
exit
# (back outside; /tmp on the host is separate from the container's /tmp)

# 6) Verify the uploaded tarball actually contains all N split files.
#    Do this OUTSIDE the container — /tmp inside singularity is container-local.
xrdcp root://cmseos.fnal.gov//store/group/lpctreasure/Condor_inputs/OPENDATA_CMSSW_${DATASET}.tgz /tmp/t.tgz
tar -tzf /tmp/t.tgz | grep -c EOS_files_split/${DATASET}
#    expected = number of jobs + 1 (the extra match is the split dir itself)
wc -l file_lists/${DATASET}.txt     # sanity: with 1 file/job, tar count above = this + 1

# 7) Submit (outside singularity; --files_per_job 1 must match the split).
python3 submit_condor_jobs.py $DATASET --submit --files_per_job 1

# 8) Watch it finish.
condor_q jen_a
./production_status.sh
```

---

## Repository layout

| File | Purpose |
|------|---------|
| `pfnano_data_2016UL_OpenData.py` | CMS config: MINIAOD → PFNano (data) |
| `pfnano_mc_2016UL_OpenData.py` | CMS config: MINIAOD → PFNano (MC) |
| `H5_maker_FOE.py` | PFNano → HDF5 (jets + PFCandidates) |
| `H5_merge.py` | merge `.h5` outputs |
| `Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt` | golden JSON of validated 2016 runs |
| `fetch_file_lists.py` | download dataset file lists from CERN Open Data |
| `split_file_list.py` | split a file list into per-job lists |
| `doCondor.py` | build/upload dataset tarball; submit, monitor, resubmit |
| `submit_condor_jobs.py` | one-command per-dataset runner (split + tar + submit) |
| `verify_condor_jobs.sh` | per-dataset OK/RUNNING/FAILED report |
| `production_status.sh` | one-glance progress chart over all datasets |
| `makeMyScripts.sh` | regenerate the job-script template |
| `test_e2e.sh` | local end-to-end test (single file, no condor) |
| `test_condor_preflight.sh` / `test_condor_submit.sh` | 2-file condor pipeline test |
| `condor_script_templates/` | job-script templates for the worker |

## Useful links

- [CMS Open Data Guide](https://cms-opendata-guide.web.cern.ch/)
- [2016 MINIAOD datasets on the CERN Open Data portal](https://opendata.cern.ch/search?f=experiment%3ACMS&f=type%3ADataset%2Bsubtype%3ACollision&f=file_type%3Aminiaod&f=year%3A2016--2016)
- [Validated 2016 runs (golden JSON)](https://opendata.cern.ch/record/14220)
- [NanoAOD format](https://twiki.cern.ch/twiki/bin/view/CMSPublic/WorkBookNanoAOD)
- [PFNano](https://opendata.cern.ch/record/12504) · [NanoAODTools](https://opendata.cern.ch/record/12507)