import h5py
import sys
import numpy as np
import matplotlib.pyplot as plt

#f = h5py.File("/eos/uscms/store/user/pjana/Condor_outputs/H5_maker_ZeroBias_2016G/ZeroBias_2016G_job0.h5", "r")
f = h5py.File("/eos/uscms/store/user/pjana/H5_output/outfile.h5", "r")

print(list(f.keys()))  

# Access arrays:
event_info = f["event_info"][:]
pfcands = f["PFCands"][:]

print(event_info.shape)
print(pfcands.shape)

def plot_histogram(data, variable_name, bins=50, range=None, log=False, save_path=None):
    """
    Plot a histogram of a given variable.

    Parameters:
    - data: array-like, data to plot
    - variable_name: str, name of the variable (used for labels and title)
    - bins: int, number of histogram bins
    - range: tuple, (min, max) for histogram range
    - log: bool, whether to use logarithmic scale
    - save_path: str or None, path to save the plot. If None, plot is not saved.
    """
    plt.figure()
    plt.hist(data, bins=bins, range=range, log=log)
    plt.xlabel(variable_name)
    plt.ylabel("Counts")
    plt.title("{} Distribution".format(variable_name)) 
    if save_path:
        plt.savefig(save_path, dpi=300)
    plt.show()


#pZ
# pZ = f['PFCands'][:, :, 2].flatten()
# print(pZ.shape)
# plt.figure()
# plt.hist(pZ, bins=41, range=(-20, 20))
# plt.xlabel("PF Candidate pZ [GeV]")
# plt.ylabel("Counts")
# plt.title("PF Candidate pZ Distribution")
# plt.savefig("Plots/pfcand_pZ_condor.png", dpi=300)   # Save plot
# plt.show() 
# #Energy
# energy = f['PFCands'][:, :, 3].flatten()
# print(energy.shape)
# print(energy[:2])
# plt.figure()
# plt.hist(energy, bins=300, range=(0, 300), log=True)
# plt.xlabel("PF Candidate Energy [GeV]")
# plt.ylabel("Counts")
# plt.title("PF Candidate Energy Distribution")
# plt.savefig("Plots/pfcand_energy_condor.png", dpi=300)   # Save plot
# plt.show()
# #pt
# Px = f['PFCands'][:, :, 0]
# Py = f['PFCands'][:, :, 1]
# pT = np.sqrt(Px**2 + Py**2).flatten()
# print(pT[:2])
# plt.figure()
# plt.hist(pT, bins=120, range=(0, 120), log=True)
# plt.xlabel("PF Candidate pT [GeV]")
# plt.ylabel("Counts")
# plt.title("PF Candidate pT Distribution")
# plt.savefig("Plots/pfcand_pT_condor.png", dpi=300)   # Save plot
# plt.show()
#pdgId
# pdgId = f['PFCands'][:, :, 9].flatten()
# print(pdgId[:2])
# plt.figure()
# plt.hist(pdgId, bins=230, range=(0, 230), log=True)
# plt.xlabel("PF Candidate pdgId")
# plt.ylabel("Counts")
# plt.title("PF Candidate pdgId Distribution")
# plt.savefig("Plots/pfcand_pdgId_singlefile.png", dpi=300)   # Save plot
# plt.show()
# Example usage for d0Err:
puppiWeight = f['PFCands'][:, :, 10].flatten()
plot_histogram(puppiWeight, "PF Candidate puppiWeight", bins=50, range=(0, 1), log=True, save_path="Plots/pfcand_puppiWeight_singlefile.png")