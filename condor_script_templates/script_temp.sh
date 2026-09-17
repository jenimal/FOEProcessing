#!/bin/bash

set -ex

FOEDIR=$(ls -d FOE*[Pp]* 2>/dev/null | head -1)
cd ${FOEDIR:-FOEProcessing}/
eval `scramv1 runtime -sh`
cmsRun pfnano_data_2016UL_OpenData.py inputFiles_load=EOS_files_split/CMS_Run2016G_Charmonium_MINIAOD_UL2016_MiniAODv2-v1/CMS_Run2016G_Charmonium_MINIAOD_UL2016_MiniAODv2-v1_job${2}.txt 
python H5_maker_FOE.py -i nano_data2016.root -o CMS_Run2016G_Charmonium_MINIAOD_UL2016_MiniAODv2-v1_job${2}.h5 -j Cert_271036-284044_13TeV_Legacy2016_Collisions16_JSON.txt 
xrdcp -f CMS_Run2016G_Charmonium_MINIAOD_UL2016_MiniAODv2-v1_job${2}.h5 ${1} 
