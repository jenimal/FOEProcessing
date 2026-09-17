#!/bin/bash

set -ex

FOEDIR=$(ls -d FOE*[Pp]* 2>/dev/null | head -1)
cd ${FOEDIR:-FOEProcessing}/
eval `scramv1 runtime -sh`
cmsRun pfnano_mc_2016UL_OpenData.py inputFiles_load=${2}.txt 
python H5_maker.py -i nano_mc2016.root -o 2016G_job${2}.h5 
xrdcp -f 2016G_job${2}.h5 ${1} 
