#!/bin/bash
# Start all test Neo4j graphs as Apptainer instances.
# Apptainer-only equivalent of start_neo4j_test.sh.
#
# Usage:
#   bash docker/start_neo4j_test_apptainer.sh [--sif_path path]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APPTAINER=$(command -v apptainer || command -v singularity)
if [ -z "$APPTAINER" ]; then
    echo "Error: Neither apptainer nor singularity found."
    exit 1
fi

SIF_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sif_path) SIF_PATH="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

BENCHMARK_DIR="$PROJECT_DIR/benchmark"

if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "Error: The folder $BENCHMARK_DIR does not exist."
    exit 1
fi

declare -a graphs=(
    "company:15062"
    "fictional_character:15063"
    "flight_accident:15064"
    "geography:15065"
    "movie:15066"
    "nba:15067"
    "politics:15068"
)

missing_files=false
for entry in "${graphs[@]}"; do
    graph="${entry%%:*}"
    graph_path="$BENCHMARK_DIR/graphs/simplekg/${graph}_simplekg.json"
    if [ ! -f "$graph_path" ]; then
        echo "Error: Missing graph file $graph_path"
        missing_files=true
    fi
done

if [ "$missing_files" = true ]; then
    echo "One or more graph files are missing. Exiting."
    exit 1
fi

IMAGE="docker://megagonlabs/neo4j-with-loader:2.4"
SIF_CACHE_DIR="$PROJECT_DIR/.cache/sif"
CACHED_SIF="$SIF_CACHE_DIR/neo4j-with-loader_2.4.sif"

if [ -z "$SIF_PATH" ]; then
    if [ -f "$CACHED_SIF" ]; then
        SIF_PATH="$CACHED_SIF"
    else
        echo "Pulling SIF image (one-time cache)..."
        mkdir -p "$SIF_CACHE_DIR"
        $APPTAINER pull "$CACHED_SIF" "$IMAGE" || {
            echo "WARNING: SIF pull failed, falling back to docker:// URI"
            SIF_PATH="$IMAGE"
        }
        if [ -z "$SIF_PATH" ]; then
            SIF_PATH="$CACHED_SIF"
        fi
    fi
fi

echo "Starting Neo4j instances with $APPTAINER..."
for entry in "${graphs[@]}"; do
    graph="${entry%%:*}"
    port="${entry##*:}"
    instance="cypherbench-${graph//_/-}"

    if $APPTAINER instance list 2>/dev/null | grep -q "$instance"; then
        echo "  [SKIP] $instance already running"
        continue
    fi

    graph_json="$BENCHMARK_DIR/graphs/simplekg/${graph}_simplekg.json"
    echo "  Starting $instance on port $port..."

    $APPTAINER instance start \
        --bind "$graph_json:/init/graph.json" \
        --env "NEO4J_AUTH=$NEO4J_USERNAME/$NEO4J_PASSWORD" \
        --env "NEO4J_server_http__enabled__modules=TRANSACTIONAL_ENDPOINTS,UNMANAGED_EXTENSIONS,ENTERPRISE_MANAGEMENT_ENDPOINTS" \
        --env "NEO4J_PLUGINS=[\"apoc\",\"graph-data-science\"]" \
        --net --network-args "portmap=$port:7687/tcp" \
        "$SIF_PATH" \
        "$instance" || {
        echo "  ERROR: Failed to start $instance"
    }
done

echo "Done."
