#!/bin/bash
source ~/miniconda3/etc/profile.d/conda.sh
conda activate tpu_sim

export REF_MODEL_DIR="$(pwd)/tb"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH}"

echo "[setup_env.sh] tpu_sim activated. REF_MODEL_DIR=${REF_MODEL_DIR}"
