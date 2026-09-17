#!/usr/bin/env python
# Split a dataset file list (file_lists/<dataset>.txt) into per-condor-job
# file lists, written to:
#   EOS_files_split/<dataset>/<dataset>_job{i}.txt
#
# Usage:
#   python3 split_file_list.py <dataset> [--files_per_job N]
#
# The number of jobs is computed automatically from the number of files in
# the list. Each dataset gets its own subdirectory so that tarballs only ever
# contain one dataset and directories don't fill up with thousands of files.

import os
import sys
import argparse

def dataset_type(dataset):
    # MC file lists are conventionally named file_lists/CMS_mc_*.txt
    return "MC" if dataset.startswith("CMS_mc_") else "data"

def files_per_job_for(dataset):
    # MC files are larger; give extra jobs. Data files run faster so allow
    # more files per job. Overridable with --files_per_job.
    return 3 if dataset_type(dataset) == "MC" else 8

def main():
    parser = argparse.ArgumentParser(
        description="Split file_lists/<dataset>.txt into per-job lists under EOS_files_split/<dataset>/")
    parser.add_argument("dataset", help="Dataset name, matching file_lists/<dataset>.txt")
    parser.add_argument("--files_per_job", type=int, default=None,
                        help="Number of files per condor job. Defaults are per data/MC type.")
    parser.add_argument("--jobs_per_file", type=int, default=None,
                        help="Alternative: number of files per job (alias for --files_per_job).")
    args = parser.parse_args()

    dataset = args.dataset
    if dataset.endswith(".txt"):
        dataset = dataset[:-4]
    if "/" in dataset:
        dataset = dataset.split("/")[-1]

    inputList = os.path.join("file_lists", dataset + ".txt")
    if not os.path.exists(inputList):
        sys.exit("ERROR: input file list %s not found" % inputList)

    fpe = args.files_per_job or args.jobs_per_file or files_per_job_for(dataset)

    f_list = [line for line in open(inputList) if line.strip()]
    num_lines = len(f_list)
    if num_lines == 0:
        sys.exit("ERROR: %s is empty" % inputList)

    nJobs = -(-num_lines // fpe)  # ceil division

    odir = os.path.join("EOS_files_split", dataset)
    if os.path.exists(odir):
        os.system("rm -rf %s" % odir)
    os.makedirs(odir)

    label = "%s_job%%i" % dataset

    for i in range(nJobs):
        f_out = f_list[i * fpe:(i + 1) * fpe]
        out_file = open(os.path.join(odir, label % i) + ".txt", "w")
        for line in f_out:
            out_file.write(line)
        out_file.close()

    print("Split %d files into %d jobs (%d files/job)" % (num_lines, nJobs, fpe))
    print("Output: %s/%s_job{i}.txt" % (odir, dataset))
    print("Type: %s" % dataset_type(dataset))

if __name__ == "__main__":
    main()
