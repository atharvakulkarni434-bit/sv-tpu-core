#!/bin/bash
# Works whether conda.sh exists (typical) or only bin/activate does.
if [ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]; then
    source "$HOME/miniconda3/etc/profile.d/conda.sh"
    conda activate tpu_sim
else
    source "$HOME/miniconda3/bin/activate" tpu_sim
fi

export REF_MODEL_DIR="$(pwd)/tb"
export LD_LIBRARY_PATH="${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH}"
echo "[setup_env.sh] tpu_sim activated. REF_MODEL_DIR=${REF_MODEL_DIR}"
