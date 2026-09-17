#!/usr/bin/env python3
"""Fetch MINIAOD file lists from the CERN Open Data portal.

The portal does not hand out plain .txt file lists from its web UI — the
"Files and indexes" section only offers JSON file indexes. The full list of
EOS file URIs for a dataset is embedded in the record's metadata
(_file_indices), so this script pulls that API JSON and writes one
root://eospublic.cern.ch URI per line to:
    file_lists/<dataset>.txt

The dataset name is derived automatically from the EOS path structure:
    .../cms/<RunPeriod>/<Dataset>/MINIAOD/<UL2016_...>/
becomes
    CMS_<RunPeriod>_<Dataset>_MINIAOD_<UL2016_...>.txt

Usage:
    python3 fetch_file_lists.py <record_id> [<record_id> ...]
    python3 fetch_file_lists.py --all          # all CMS 2016 UL MINIAOD records
    python3 fetch_file_lists.py 30508 30541    # e.g. JetHT 2016G + 2016H

Requires only the Python 3 standard library (urllib); no websocket/xrootd
needed. Run from the FOEProceessing working area.

The record IDs for the CMS Run-2016 open-data MINIAOD datasets are stable
and listed below (see opendata.cern.ch /record/<id>).
"""

import argparse
import json
import os
import re
import sys
import urllib.request

# CMS 2016 UL MINIAOD records: {record_id: (trigger/dataset name, era)}
# 17 datasets x eras G/H — pulled from the "CMS Open Datasets" sheet, col C.
CMS_2016_UL_MINIAOD = {
    30500: "BTagCSV_2016G",      30533: "BTagCSV_2016H",
    30501: "BTagMu_2016G",       30534: "BTagMu_2016H",
    30502: "Charmonium_2016G",   30535: "Charmonium_2016H",
    30503: "DisplacedJet_2016G", 30536: "DisplacedJet_2016H",
    30504: "DoubleEG_2016G",     30537: "DoubleEG_2016H",
    30505: "DoubleMuon_2016G",   30538: "DoubleMuon_2016H",
    30506: "DoubleMuonLowMass_2016G", 30539: "DoubleMuonLowMass_2016H",
    30507: "HTMHT_2016G",        30540: "HTMHT_2016H",
    30508: "JetHT_2016G",        30541: "JetHT_2016H",
    30509: "MET_2016G",          30542: "MET_2016H",
    30510: "MuOnia_2016G",       30543: "MuOnia_2016H",
    30511: "MuonEG_2016G",       30544: "MuonEG_2016H",
    30512: "SingleElectron_2016G", 30545: "SingleElectron_2016H",
    30513: "SingleMuon_2016G",   30546: "SingleMuon_2016H",
    30514: "SinglePhoton_2016G", 30547: "SinglePhoton_2016H",
    30515: "Tau_2016G",          30548: "Tau_2016H",
    30516: "ZeroBias_2016G",     30549: "ZeroBias_2016H",
}

API = "https://opendata.cern.ch/api/records/{id}"


def derive_name(uri):
    """CMS_Run2016G_BTagMu_MINIAOD_UL2016_MiniAODv2-v1  from an eospublic path."""
    m = re.search(r"/cms/(Run\d+[A-Z])/([^/]+)/MINIAOD/([^/]+)/", uri)
    if not m:
        raise ValueError("cannot derive dataset name from URI: %s" % uri)
    return "CMS_%s_%s_MINIAOD_%s" % (m.group(1), m.group(2), m.group(3))


def fetch_uris(record_id):
    """Return the ordered list of EOS file URIs for a record."""
    with urllib.request.urlopen(API.format(id=record_id), timeout=120) as r:
        data = json.load(r)
    md = data.get("metadata", {})
    uris = []
    for fi in md.get("_file_indices", []):
        for f in fi.get("files", []):
            uris.append(f["uri"])
    if not uris:
        print("  [WARN] record %s: no files found (title=%r)" % (record_id, md.get("title", "")))
    return uris


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("records", nargs="*", type=int,
                    help="CERN Open Data record id(s), e.g. 30508")
    ap.add_argument("--all", action="store_true",
                    help="fetch every CMS 2016 UL MINIAOD record")
    ap.add_argument("--out", default="file_lists",
                    help="output directory (default: file_lists)")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be written, don't write files")
    args = ap.parse_args()

    ids = list(args.records)
    if args.all:
        ids = sorted(CMS_2016_UL_MINIAOD)
    if not ids:
        ap.error("give at least one record id, or --all")

    os.makedirs(args.out, exist_ok=True)

    for rid in ids:
        label = CMS_2016_UL_MINIAOD.get(rid, "?")
        print("== record %s (%s)" % (rid, label))
        try:
            uris = fetch_uris(rid)
        except Exception as e:
            print("  [ERROR] %s" % e)
            continue
        if not uris:
            continue

        name = derive_name(uris[0])
        path = os.path.join(args.out, name + ".txt")
        n_dup = len(uris) - len(set(uris))
        if n_dup:
            print("  [WARN] %d duplicate URIs removed" % n_dup)
            uris = sorted(set(uris))

        if args.dry_run:
            print("  [dry-run] would write %s (%d files)" % (path, len(uris)))
            continue

        with open(path, "w") as f:
            f.write("\n".join(uris) + "\n")
        print("  wrote %s (%d files)" % (path, len(uris)))


if __name__ == "__main__":
    main()