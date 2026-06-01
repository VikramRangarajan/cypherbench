#!/bin/bash
# Start all sampled Neo4j graphs as Apptainer instances.
#
# Usage:
#   bash docker/start_neo4j_sampled_apptainer.sh [--sif_path path] [--rebuild-sif]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APPTAINER=$(command -v apptainer || command -v singularity)
if [ -z "$APPTAINER" ]; then
    echo "Error: Neither apptainer nor singularity found."
    exit 1
fi

SIF_PATH=""
REBUILD_SIF=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --sif_path) SIF_PATH="$2"; shift 2 ;;
        --rebuild-sif) REBUILD_SIF=true ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

source "$SCRIPT_DIR/.env"

BENCHMARK_DIR="$PROJECT_DIR/benchmark"

if [ ! -d "$BENCHMARK_DIR" ]; then
    echo "Error: The folder $BENCHMARK_DIR does not exist."
    exit 1
fi

declare -a graphs=(
    "art:15080"
    "biology:15081"
    "company:15082"
    "fictional_character:15083"
    "flight_accident:15084"
    "geography:15085"
    "movie:15086"
    "nba:15087"
    "politics:15088"
    "soccer:15089"
    "terrorist_attack:15090"
)

missing_files=false
for entry in "${graphs[@]}"; do
    graph="${entry%%:*}"
    graph_path="$BENCHMARK_DIR/graphs/simplekg_sampled/${graph}_sampled_simplekg.json"
    if [ ! -f "$graph_path" ]; then
        echo "Error: Missing graph file $graph_path"
        missing_files=true
    fi
done

if [ "$missing_files" = true ]; then
    echo "One or more graph files are missing. Exiting."
    exit 1
fi

DEF_FILE="$SCRIPT_DIR/neo4j-with-loader/neo4j-with-loader.def"
SIF_CACHE_DIR="$PROJECT_DIR/.cache/sif"
SIF_NAME="neo4j-with-loader.sif"
CACHED_SIF="$SIF_CACHE_DIR/$SIF_NAME"

if [ -z "$SIF_PATH" ]; then
    if [ -f "$CACHED_SIF" ] && [ "$REBUILD_SIF" = false ]; then
        SIF_PATH="$CACHED_SIF"
    else
        if [ "$REBUILD_SIF" = true ]; then
            echo "Rebuilding SIF from definition file..."
            rm -f "$CACHED_SIF"
        else
            echo "Building SIF from definition file (one-time cache)..."
        fi
        mkdir -p "$SIF_CACHE_DIR"
        BUILD_DIR="$(dirname "$DEF_FILE")"
        (cd "$BUILD_DIR" && $APPTAINER build "$CACHED_SIF" "$DEF_FILE") || {
            echo "ERROR: SIF build failed."
            exit 1
        }
        SIF_PATH="$CACHED_SIF"
    fi
fi

INSTANCE_DIR="$PROJECT_DIR/.cache/neo4j-instances"

echo "Starting Neo4j instances with $APPTAINER..."
for entry in "${graphs[@]}"; do
    graph="${entry%%:*}"
    port="${entry##*:}"
    instance="cypherbench-${graph//_/-}-sampled"

    if $APPTAINER instance list 2>/dev/null | grep -q "$instance"; then
        echo "  [SKIP] $instance already running"
        continue
    fi

    graph_json="$BENCHMARK_DIR/graphs/simplekg_sampled/${graph}_sampled_simplekg.json"
    echo "  Starting $instance on port $port..."

    http_port=$((port + 1000))

    inst_dir="$INSTANCE_DIR/$instance"
    mkdir -p "$inst_dir"/{data,logs,run,plugins}

    $APPTAINER instance start \
        --bind "$graph_json:/init/graph.json" \
        --bind "$inst_dir/data:/var/lib/neo4j/data" \
        --bind "$inst_dir/logs:/var/log/neo4j" \
        --bind "$inst_dir/run:/var/lib/neo4j/run" \
        --bind "$inst_dir/plugins:/var/lib/neo4j/plugins" \
        --env "NEO4J_AUTH=$NEO4J_USERNAME/$NEO4J_PASSWORD" \
        --env "NEO4J_PLUGINS=[\"apoc\",\"graph-data-science\"]" \
        --env "NEO4J_server_bolt_listen__address=:$port" \
        --env "NEO4J_server_bolt_advertised__address=:$port" \
        --env "NEO4J_server_http_listen__address=:$http_port" \
        --env "NEO4J_server_http_advertised__address=:$http_port" \
        "$SIF_PATH" \
        "$instance" || {
        echo "  ERROR: Failed to start $instance"
    }
done

echo "Done."
