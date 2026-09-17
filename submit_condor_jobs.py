import sys, os, argparse

def print_and_do(s):
    print(s)
    return os.system(s)


def count_lines(fname):
    with open(fname) as f:
        return sum(1 for line in f if line.strip())


def main():
    parser = argparse.ArgumentParser(
        description="Build condor job scripts for a single dataset. Run the "
                    "manual steps below in order (tar, split, submit). This can "
                    "be fully automated later by chaining them.")
    parser.add_argument("dataset",
                        help="Dataset name, matching file_lists/<dataset>.txt "
                             "(no .txt extension)")
    parser.add_argument("--mem", type=int, default=6000,
                        help="Memory per job in MB (default 6000)")
    parser.add_argument("--files_per_job", type=int, default=None,
                        help="Files per condor job. Defaults per data/MC type "
                             "(3 MC, 8 data).")
    parser.add_argument("--submit", action="store_true",
                        help="Also submit the jobs after building them "
                             "(otherwise just build and print the commands).")
    args = parser.parse_args()

    dataset = args.dataset
    if dataset.endswith(".txt"):
        dataset = dataset[:-4]

    eos_base = "root://cmseos.fnal.gov/"

    mc = dataset.startswith("CMS_mc_")
    label = dataset

    # Number of jobs = number of files in the per-dataset list (uniform rules
    # with split_file_list.py so the job count matches the split files).
    fpe = args.files_per_job or (3 if mc else 8)
    nLines = count_lines(os.path.join("file_lists", dataset + ".txt"))
    nJobs = -(-nLines // fpe)  # ceil division

    print("Dataset: %s (%s)" % (dataset, "MC" if mc else "data"))
    print("Files: %d, files/job: %d, nJobs: %d" % (nLines, fpe, nJobs))

    if nJobs <= 0:
        sys.exit("ERROR: no files found in file_lists/%s.txt" % dataset)

    oname = label + "_job${2}.h5"

    script_name = "condor_script_templates/script_temp.sh"
    print_and_do("cp condor_script_templates/h5_template.sh %s" % script_name)
    f = open(script_name, "a")

    # Split lists live in a per-dataset subdirectory:
    #   EOS_files_split/<dataset>/<dataset>_job{j}.txt
    split_path = "EOS_files_split/%s/%s_job${2}.txt" % (dataset, dataset)

    if not mc:
        cmd_PFNano = "cmsRun pfnano_data_2016UL_OpenData.py inputFiles_load=%s \n" % split_path
        cmd_h5 = "python H5_maker_FOE.py -i nano_data2016.root -o %s -j Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt \n" % oname
    else:
        cmd_PFNano = "cmsRun pfnano_mc_2016UL_OpenData.py inputFiles_load=%s \n" % split_path
        cmd_h5 = "python H5_maker_FOE.py -i nano_mc2016post.root -o %s --sample_type MC \n" % oname

    f.write(cmd_PFNano)
    f.write(cmd_h5)

    cp_cmd = "xrdcp -f %s ${1} \n" % (oname)
    f.write(cp_cmd)
    f.close()

    print_and_do("chmod +x %s" % script_name)

    sub_cmd = ("python3 doCondor.py --njobs %i --mem %.0f --overwrite --cmssw --sub "
               "-d %s -s %s -n %s" % (nJobs, args.mem, dataset, script_name, label))
    if args.submit:
        print_and_do(sub_cmd)
    else:
        print("\nJob scripts built. Manual steps (run in order):\n")
        print("  1. Split the file list into per-job lists:")
        print("     python3 split_file_list.py %s --files_per_job %d" % (dataset, fpe))
        print("  2. Build/refresh the tarball with only this dataset (run AFTER splitting):")
        print("     python3 doCondor.py --tar -d %s" % dataset)
        print("  3. Submit the jobs (submit_condor_jobs.py with --submit, or):")
        print("     %s" % sub_cmd)

if __name__ == "__main__":
    main()
