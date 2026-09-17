#!/bin/bash

set -ex

# cd into the FOE analysis directory (named differently across versions, e.g.
# FOEProcessing vs FOEProceessing). Auto-detect so we don't depend on the exact
# directory name.
FOEDIR=$(ls -d FOE*[Pp]* 2>/dev/null | head -1)
cd ${FOEDIR:-FOEProcessing}/
eval `scramv1 runtime -sh`
