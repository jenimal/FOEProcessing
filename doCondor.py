#!/usr/bin/env python

# doCondor.py #############################################################################
# Python driver for submitting condor jobs 
# Oz Amram


# ------------------------------------------------------------------------------------


import subprocess
import sys, os, fnmatch, glob
from optparse import OptionParser
from optparse import OptionGroup
from numpy import arange
from itertools import product
import argparse
import re

default_args = []

# Options

def condor_options():

    parser = argparse.ArgumentParser()
    parser.add_argument("-d", "--dataset", default='',
            help="Name of dataset to isolate. When tarring, excludes all other datasets' split lists so the tarball only contains this dataset.")
    parser.add_argument("-o", "--outdir", default='condor_jobs/',
            help="output for analyzer. This will always be the output for job scripts.")
    parser.add_argument("-n", "--name", default='', 
            help="Name of job. Will be used for eos output and local directory")
    parser.add_argument("-v", "--verbose", dest="verbose", default=False, action="store_true", 
            help="Spit out more info")
    parser.add_argument("-i", "--input", default=[], help="Additional list of files to be used as input (comma separated)")
    parser.add_argument("--job_list", default=[], help="Idxs to actually sub")
    # Make condor submission scripts arguments
    parser.add_argument("--njobs", dest="nJobs", type=int, default=0, help="Split into n jobs, will automatically produce submission scripts")
    parser.add_argument("-s", "--script", dest="script", default="scripts/my_script.sh",
            help="sh script to be run by jobs (if splitting, should take eosoutput, nJobs and iJob as args)")
    parser.add_argument("--dry-run", dest="dryRun", default=False, action="store_true", 
            help="Do nothing, just create jobs if requested")

    # Monitor arguments (submit,check,resubmit failed)  -- just pass outodir as usual but this time pass --monitor sub --monitor check or --monitor resub
    parser.add_argument("--sub", default=False, action="store_true", help="Submit jobs")
    parser.add_argument("--resub", default=False, action="store_true", help="Re submit failed job")

    parser.add_argument("-e", "--haddEOS", dest='haddEOS', default = False, action='store_true',  help="Hadd EOS files together and save in output_files/YEAR directory")
    parser.add_argument("-g", "--getEOS", default = False, action='store_true',  help="Get EOS files and save to out directory")
    parser.add_argument("-y", "--year", dest='year', type=int, default = 2016,  help="Year for output file location")

    parser.add_argument("--tar", dest='tar', default = False, action='store_true',  help="Create tarball of current directory")
    parser.add_argument("--tarname", dest='tarname', default = "OPENDATA_CMSSW.tgz", help="Name of directory to tar (relative to cmssw_base)")
    parser.add_argument("--tarexclude", dest='tarexclude', default = '', 
            help="Name of directories to exclude from the tar (relative to cmssw_base), format as comma separated string (eg 'dir1, dir2') ")
    parser.add_argument("--cmssw", default = False, action="store_true",  help="Use full CMSSW tarball")
    parser.add_argument("--case", default = False, action="store_true",  help="Shortcut to create tarball for case  analysis")
    parser.add_argument("--root_files", dest='root_files', default = False, action="store_true",  help="Shortcut to create tarball for root files of AFB analysis")
    parser.add_argument("--no_rename", default = False, action="store_true",  help="Don't rename files for storing on EOS")
    parser.add_argument("--mem", default = 0, type=int,  help="Request extra memory")
    parser.add_argument("--overwrite", default = False, action='store_true',  help="Overwrite output dir instead of making new one (+x to name)")
    return parser



def doCondor(options):
    cwd = os.getcwd()
    # Use RELATIVE paths (resolved against the submission working directory as
    # seen by the submit host) for everything condor transfers. Using
    # os.path.abspath() bakes in the cwd captured inside the singularity
    # container, which can be a different mount (e.g. /uscms_data/d2/...)
    # than the path the submit host can actually read (/uscms/home/...),
    # causing "errno 2 No such file or directory" on transfer of my_script.sh.
    # Hoisted here so both --sub and --resub build the same .jdl.
    rel = lambda p: os.path.relpath(p, cwd)
    script_location = rel(os.path.abspath(options.outdir + options.name + "/my_script.sh"))
    #if len(args) < 1 and (not options.monitor or not options.tar) : sys.exit('Error -- must specify ANALYZER')
    cmssw_ver = os.getenv('CMSSW_VERSION', 'CMSSW_10_6_30')
    xrd_base = 'root://cmseos.fnal.gov/'
    # Where on EOS the production areas live. Override with the environment
    # variable FOE_EOS_STORE (a /store/... path without trailing slash), e.g.
    #   export FOE_EOS_STORE=/store/group/lpctreasure
    # Defaults to the group's shared /store/group/lpctreasure area on
    # cmseos.fnal.gov. Point it elsewhere (e.g. your private /store/user/<user>)
    # by exporting FOE_EOS_STORE before running any doCondor.py command.
    _store = os.environ.get('FOE_EOS_STORE', '/store/group/lpctreasure').rstrip('/')
    EOS_home = _store + '/'
    EOS_base = xrd_base + EOS_home
    EOS_base_local = "/eos/uscms" + EOS_home
    scram_arch = 'slc7_amd64_gcc700'
    cmssw_name = 'CMSSW_10_6_30'

    # Resolve the CMSSW release root (the directory named CMSSW_*). Prefer the
    # environment, but fall back to walking up from this script so --tar works
    # even when run outside a cmsenv'd shell.
    def resolve_cmssw_base():
        env_base = os.environ.get('CMSSW_BASE', '')
        if env_base:
            return env_base
        d = os.path.dirname(os.path.abspath(__file__))
        while os.path.isdir(d) and d != '/':
            if os.path.basename(d).startswith('CMSSW_'):
                return d
            d = os.path.dirname(d)
        return ''

    cmssw_base = resolve_cmssw_base()

    # write job
    def write_job(out, name, nJobs, iJob, eosout='', tarname = ''):
        #print 'job_i %i nfiles %i subjobi %i'%(i,n,j)
        cwd = os.getcwd()
        eos_cmssw_file = EOS_base + 'Condor_inputs/' + tarname

        sub_file = open('%s/%s_job%d.sh' % (out, name, iJob), 'w')
        sub_file.write('#!/bin/bash\n')
        sub_file.write('# Job Number %d, of %d \n' % (iJob, nJobs))
        sub_file.write('set -x \n')
        sub_file.write('source /cvmfs/cms.cern.ch/cmsset_default.sh\n')
        sub_file.write('pwd\n')
        sub_file.write('export SCRAM_ARCH=%s\n' % scram_arch)

        sub_file.write('xrdcp %s case_alt_cmssw.tgz \n' % eos_cmssw_file) 
        sub_file.write('cat my_script.sh \n')
        sub_file.write('tar -xzf case_alt_cmssw.tgz \n')
        sub_file.write('ls \n')
        sub_file.write('mv my_script.sh %s/src/ \n' % cmssw_name)
        sub_file.write('cd %s/src \n' % cmssw_name)
        sub_file.write('ls \n')
        sub_file.write('eval `scramv1 runtime -sh`\n')
        sub_file.write('scram b ProjectRename \n')
        sub_file.write('scram b -j \n')

        sub_file.write('./my_script.sh %s %i \n' % (eosout,iJob))
        sub_file.write('cd ${_CONDOR_SCRATCH_DIR} \n')
        sub_file.write('rm -rf %s\n' % cmssw_name)
        sub_file.close()
        os.system('chmod +x %s' % os.path.abspath(sub_file.name))

    # write condor submission script

    # Write a condor .jdl submission file for a job script. Shared by the fresh
    # submit path and --resub so a missing/stale .jdl never blocks a resubmit
    # (e.g. after --overwrite regenerated only the .sh scripts).
    def write_jdl(sub_file):
        condor_file = open('%s.jdl' % sub_file, 'w')
        rel_sub_file = rel(os.path.abspath(sub_file))
        condor_file.write('universe = vanilla\n')
        condor_file.write('Executable = %s\n'% rel_sub_file)
        condor_file.write('Requirements = OpSys == "LINUX"&& (Arch != "DUMMY" )\n')
        condor_file.write('+ApptainerImage = "/cvmfs/singularity.opensciencegrid.org/cmssw/cms:rhel7" \n')
        #condor_file.write('request_disk = 500000\n') # modify these requirements depending on job
        if(options.mem > 0. ): condor_file.write('request_memory = %i \n' % options.mem)
        condor_file.write('Should_Transfer_Files = YES\n')
        input_files = "Transfer_Input_Files = %s, %s " %(script_location, rel_sub_file)
        for f in options.input:
            base = os.path.join(options.outdir + options.name, f.split("/")[-1])
            input_files += " , "  + rel(os.path.abspath(base))
        condor_file.write(input_files + "\n")
        condor_file.write('WhenToTransferOutput = ON_EXIT \n')
        condor_file.write('use_x509userproxy = true\n')
        condor_file.write('x509userproxy = $ENV(X509_USER_PROXY)\n')
        condor_file.write('Output = %s.stdout\n' % rel(os.path.abspath(condor_file.name)))
        condor_file.write('Error = %s.stdout\n' % rel(os.path.abspath(condor_file.name)))
        condor_file.write('Log = %s.log\n' % rel(os.path.abspath(condor_file.name)))
        condor_file.write('Queue 1\n')
        condor_file.close()
        os.system('chmod +x %s'% os.path.abspath(condor_file.name))

    def resubmit_jobs(lofjobs):
        for sub_file in lofjobs:
            os.system('mv %s.jdl.stdout %s.jdl.v1_stdout ' % (sub_file, sub_file))
            os.system('mv %s.jdl.log %s.jdl.v1_log' % (sub_file, sub_file))
            write_jdl(sub_file)
            os.system('condor_submit %s ' % os.path.abspath('%s.jdl' % sub_file))


    def submit_jobs(lofjobs):
        for sub_file in lofjobs:
            #os.system('rm -f %s.stdout' % sub_file)
            #os.system('rm -f %s.stderr' % sub_file)
            #os.system('rm -f %s.log' % sub_file)
            #os.system('rm -f %s.jdl'% sub_file)
            write_jdl(sub_file)
            os.system('condor_submit %s' %(rel(os.path.abspath(sub_file + '.jdl'))))




    # Build a dataset-specific tarball name so different datasets don't
    # collide on EOS.  This MUST be decided consistently for BOTH tarring and
    # submitting: write_job() bakes this name into the worker script's xrdcp,
    # so --sub has to fetch the same dataset-specific tarball that --tar -d
    # produced, or jobs download a stale/generic tarball.  Fall back to the
    # plain --tarname when no dataset is given.
    if options.dataset:
        tarball_name = "OPENDATA_CMSSW_%s.tgz" % options.dataset
    else:
        tarball_name = options.tarname if options.tarname.endswith('.tgz') else options.tarname + '.tgz'
    options.tarname = tarball_name

    if options.tar:
        print("tarring CMSSW -> %s" % tarball_name)
        print("  working dir: %s" % os.path.basename(cwd))

        # The tarball carries the CMSSW scaffold (symlink farm) and only the
        # source subtrees the job actually needs: the FOE analysis working dir
        # and the compiled PhysicsTools packages (PFNano / NanoAODTools), which
        # the worker recompiles with `scram b` against the mounted cvmfs release.
        #
        # Everything else under the release is excluded via --exclude so the
        # tarball only ever contains the code you're working on, plus the
        # required scaffold. With -d/--dataset, only that dataset's split lists
        # are kept.
        #
        # NOTE: `--exclude` paths match ANY component of the archive path, so we
        # use patterns that are anchored enough to never drop the required source
        # but broad enough to strip extraneous files.

        # 1. Peek at what's actually under src/ so we ship only the real source
        #    subtrees and not unrelated symlink stubs from a full release.
        src_parent = os.path.join(cmssw_base, "src")
        allowed_src = set()
        if os.path.isdir(src_parent):
            for name in os.listdir(src_parent):
                if name.startswith("FOE"):        # the analysis working dir
                    allowed_src.add(name)
                elif name == "PhysicsTools":      # PFNano / NanoAODTools source
                    allowed_src.add(name)
        else:
            # Fall back to only shipping the working dir by name.
            allowed_src.add(os.path.basename(cwd))
        print("  shipping these src subtrees: %s" % sorted(allowed_src))

        tar_cmd = "tar"
        # Drop every src/ subtree that is not the analysis dir or PhysicsTools.
        # Archive member names start with CMSSW_10_6_30/ (no leading component),
        # so the pattern must anchor on the release name with NO leading '*'.
        if os.path.isdir(src_parent):
            for name in sorted(os.listdir(src_parent)):
                if name not in allowed_src:
                    tar_cmd += " --exclude='%s' " % ("%s/src/%s/*" % (cmssw_name, name))

        # ---- hygiene: never ship junk/mutables/output from past runs ----
        tar_cmd += " --exclude='%s' " %'*.png'
        tar_cmd += " --exclude='%s' " %'*.root'
        tar_cmd += " --exclude='%s' " %'*.h5'
        tar_cmd += " --exclude='%s' " %'*.tgz'          # never retar past tarballs
        tar_cmd += " --exclude='%s' " %'.git'
        tar_cmd += " --exclude='%s' " %'__pycache__'
        tar_cmd += " --exclude='%s' " %'*.pyc'
        # Condor job scripts, JDLs, and past job output/logs never belong in the
        # tarball. Matches condor_jobs anywhere under the release (including the
        # scram tmp/ skeleton that caused the earlier 4-file warning, and the
        # bare empty condor_jobs/ dir left by the legacy FOEProcessing tree).
        tar_cmd += " --exclude='%s' " %'*/condor_jobs'
        # The legacy, misspelled FOEProcessing (single-c) analysis tree is stale
        # junk from an earlier naming and carries only old condor_jobs/, file
        # lists, and build caches. Never ship it.
        tar_cmd += " --exclude='%s' " %'*/FOEProcessing/*'
        # User-facing docs/plots are noise on the worker.
        tar_cmd += " --exclude='%s' " %'*FOEProceessing/Plots/*'

        # 2. With -d/--dataset: keep only THIS dataset's split lists, drop every
        #    other dataset's EOS_files_split/<dataset>/ subdir.
        if options.dataset:
            eos_split_dir = None
            for root, dirs, files in os.walk(cmssw_base):
                if os.path.basename(root) == "EOS_files_split":
                    eos_split_dir = root
                    break
            if eos_split_dir:
                for d in sorted(os.listdir(eos_split_dir)):
                    if d != options.dataset and os.path.isdir(os.path.join(eos_split_dir, d)):
                        print("excluding other dataset split lists: %s" % d)
                        tar_cmd += " --exclude='%s' " % ("*/EOS_files_split/%s/*" % d)
                # Also drop the per-dataset file_lists/<dataset>.txt for every
                # OTHER dataset (keeps the tarball clean and dataset-specific).
                file_lists_dir = os.path.join(cwd, "file_lists")
                if os.path.isdir(file_lists_dir):
                    for fl in sorted(os.listdir(file_lists_dir)):
                        if (fl.endswith(".txt") and fl != options.dataset + ".txt"
                                and not fl.startswith(options.dataset + "_")):
                            tar_cmd += " --exclude='%s' " % ("*/file_lists/%s" % fl)
            else:
                print("WARNING: dataset '%s' given but EOS_files_split not found under "
                      "%s; not excluding other dataset split lists"
                      % (options.dataset, cmssw_base))

        tar_cmd += " -zcvf %s -C %s %s" % (options.tarname, os.path.join(cmssw_base, ".."), cmssw_name)


        print("Executing tar command %s \n" % tar_cmd)
        os.system(tar_cmd)
        cp_cmd = "xrdcp -f %s %s" %(options.tarname, EOS_base + "Condor_inputs/")
        print(cp_cmd)
        os.system(cp_cmd)
        rm_cmd = "rm %s" %(options.tarname)
        os.system(rm_cmd)
        sys.exit("Finished tarring")

    elif (options.haddEOS):
        if(options.outdir != "condor_jobs/"): o_dir = options.outdir
        else: o_dir = "output_files/" + str(options.year) + "/" 
        hadd_cmd = "hadd -f " + o_dir + options.name + ".root"
        xrdfsls = "xrdfs root://cmseos.fnal.gov ls"
        hadd_cmd += " `%s -u %s | grep '.root' `" %(xrdfsls, EOS_home + 'Condor_outputs/' + options.name)
        print("Going to execute cmd %s: " % hadd_cmd)
        os.system(hadd_cmd)

    elif (options.getEOS):
        print("Getting files and outputting to %s" % options.outdir)
        result = subprocess.check_output(["./../condor/get_crab_file_list.sh", EOS_home + 'Condor_outputs/' + options.name]).decode("utf-8")
        print(result)
        for f in result.splitlines():
            cmd = "xrdcp  -f %s %s" % (f, options.outdir)
            #print "Going to execute cmd %s: " % cmd
            os.system(cmd)



    elif options.nJobs > 0:
    # -- MAIN
        if(options.name == ""): sys.exit("ERROR: MUST PROVIDE JOB NAME \n")
        if(options.overwrite):
            if(os.path.exists(options.outdir + options.name)):
                os.system("rm -r " + options.outdir + options.name)
        else:
            while(os.path.exists(options.outdir + options.name) and len(os.listdir(options.outdir + options.name)) != 0):
                print("Directory %s exists, adding an x" % options.outdir + options.name)
                options.name += "x"
                #os.system('rm -r %s' % (options.outdir + options.name))
        print("Dir is %s" %( options.outdir + options.name))
        eos_dir_name = EOS_base + 'Condor_outputs/' + options.name
        #os.system("eosrm -r %s" % eos_dir_name)
        os.system('mkdir -p %s' % (options.outdir + options.name))
        os.system('cp %s %s/my_script.sh' %(options.script, options.outdir + options.name))
        for f in options.input:
            os.system('cp %s %s/' %(f, options.outdir + options.name))

        os.system('chmod +x %s/my_script.sh' % (options.outdir + options.name))

        for iJob in range(options.nJobs):
            if(len(options.job_list) == 0 or iJob in options.job_list):
                eos_file_name = EOS_base + 'Condor_outputs/' + options.name + '/'
                write_job(options.outdir + options.name, options.name, options.nJobs, iJob, eos_file_name, tarname = options.tarname)

    # submit jobs by looping over job scripts in output dir
    if options.resub:

        odir = options.outdir + options.name + "/"
        # pick up job scripts in output directory (ends in .sh)
        lofjobs = []

        eos_out_dir = EOS_base_local + 'Condor_outputs/' + options.name + '/'

        
        finished_jobs = []
        for f_out in os.listdir(eos_out_dir):
            if('.h5' in f_out): f_out = f_out.replace(".h5", "")
            nums = [int(num) for num in re.findall(r"\d+", f_out)]
            if(len(nums) == 0): continue
            else:
                jobNum = nums[-1]
                finished_jobs.append(jobNum)

        for root, dirs, files in os.walk(odir):
            for f in fnmatch.filter(files, '%s_*.sh' %options.name):
                #lofjobs.append('%s/%s' % (os.path.abspath(root), f))
                nums = [int(num) for num in re.findall(r"\d+", f)]
                if(len(nums) == 0): continue
                else:
                    jobNum = nums[-1]
                    if(jobNum not in finished_jobs):
                        print(odir+ f, jobNum)
                        lofjobs.append(odir + f)




        print('Resubmitting %d jobs from directory %s' % (len(lofjobs), odir))
        resubmit_jobs(lofjobs)
        print("Finished submitting")
        return
    # submit jobs by looping over job scripts in output dir
    elif options.sub:
        odir = options.outdir + options.name

        # pick up job scripts in output directory (ends in .sh)
        os.system('xrdfs %s mkdir %s' % (xrd_base, EOS_home + 'Condor_outputs/' + options.name))
        lofjobs = []
        for root, dirs, files in os.walk(odir):
            for f in fnmatch.filter(files, '%s_*.sh' %options.name):
                lofjobs.append('%s/%s' % (os.path.abspath(root), f))
        print('Submitting %d jobs from directory %s' % (len(lofjobs), odir))
        submit_jobs(lofjobs)
        print("Finished submitting")
        return

if __name__ == "__main__":
    parser = condor_options()
    options = parser.parse_args()
    doCondor(options)
