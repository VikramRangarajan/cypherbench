#!/bin/bash

#SBATCH -n 1
#SBATCH -c 16
#SBATCH -t 4:00:00
#SBATCH -A gpu

#SBATCH --constraint=J
#SBATCH --mem=128G
#SBATCH --gres=gpu:1

#SBATCH -J cypherbench-sft-2
#SBATCH -o %x.out

. ~/.bashrc
module purge

# Start vllm async
export RUN_NAME=$SLURM_JOB_NAME
# cd $SCRATCH/cypher-finetune
# ADAPTER_FILE="output/$RUN_NAME/adapter_model.safetensors"

# if [[ -f "$ADAPTER_FILE" ]]; then
#     echo "LoRA adapter detected: $ADAPTER_FILE"

#     uv run vllm serve google/gemma-4-E2B-it --enable-lora --lora-modules "output/$RUN_NAME=output/$MODEL_PATH" --max-model-len 2048 &
# else
#     echo "No LoRA adapter found, serving merged/full model"

#     uv run vllm serve output/$RUN_NAME --max-model-len 2048 &
# fi

# VLLM_PID=$!
cd ~/cypherbench/docker
# Start neo4j async
INSTANCE_DIR=$HOME/cypherbench/.cache/neo4j-instances-1 bash start_neo4j_test_apptainer.sh
# Wait for vllm startup
# until curl -sf "http://0.0.0.0:8000/v1/models" >/dev/null; do
#     sleep 2
#     echo "vllm not up"
# done
# Wait for neo4j startup
cd $SCRATCH/cypher-finetune
uv run wait_until_train_db_up.py --test
cd ~/cypherbench
# uv run cypherbench/baseline/zero_shot_nl2cypher.py  --llm output/$RUN_NAME --api_base http://0.0.0.0:8000/v1 --api_key dummy  --result_dir output/$RUN_NAME --overwrite  --batch_size=128
# kill -15 $VLLM_PID
uv run cypherbench/evaluate.py --result_dir output/$RUN_NAME --num_threads 16
