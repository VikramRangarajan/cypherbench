#!/bin/bash
# Run CypherBench evaluation one graph at a time using Apptainer instances.
#
# Usage:
#   bash docker/run_eval_sequential_apptainer.sh --result_dir output/gpt-4o-mini/ [--graphs ...] [--neo4j_info neo4j_info.json] [--num_threads 1] [--timeout 600] [--rebuild-sif]
#
# If --graphs is omitted, all test domains are evaluated.
# Requires: apptainer (or singularity), python, and the benchmark graph files in ../benchmark/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APPTAINER=$(command -v apptainer || command -v singularity)
if [ -z "$APPTAINER" ]; then
    echo "Error: Neither apptainer nor singularity found."
    exit 1
fi

RESULT_DIR=""
GRAPHS=""
NEO4J_INFO="$PROJECT_DIR/neo4j_info.json"
NUM_THREADS=1
TIMEOUT=600
REBUILD_SIF=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --result_dir) RESULT_DIR="$2"; shift 2 ;;
        --graphs) GRAPHS="$2"; shift 2 ;;
        --neo4j_info) NEO4J_INFO="$2"; shift 2 ;;
        --num_threads) NUM_THREADS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --rebuild-sif) REBUILD_SIF=true ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [ -z "$RESULT_DIR" ]; then
    echo "Error: --result_dir is required"
    exit 1
fi

if [ ! -f "$RESULT_DIR/result.json" ]; then
    echo "Error: $RESULT_DIR/result.json not found. Run the baseline first."
    exit 1
fi

# Determine which graphs to process
if [ -z "$GRAPHS" ]; then
    GRAPHS=$(python3 -c "
import json
with open('$NEO4J_INFO') as f:
    info = json.load(f)
print(' '.join(info['test_domains']))
")
fi

source "$SCRIPT_DIR/.env"

# Load neo4j_info for connection details
NEO4J_INFO_DATA=$(python3 -c "
import json
with open('$NEO4J_INFO') as f:
    print(json.dumps(json.load(f)))
")

# Build SIF once
DEF_FILE="$SCRIPT_DIR/neo4j-with-loader/neo4j-with-loader.def"
SIF_CACHE_DIR="$PROJECT_DIR/.cache/sif"
CACHED_SIF="$SIF_CACHE_DIR/neo4j-with-loader.sif"

if [ ! -f "$CACHED_SIF" ] || [ "$REBUILD_SIF" = true ]; then
    echo "Building SIF from definition file..."
    mkdir -p "$SIF_CACHE_DIR"
    if [ "$REBUILD_SIF" = true ]; then
        rm -f "$CACHED_SIF"
    fi
    BUILD_DIR="$(dirname "$DEF_FILE")"
    (cd "$BUILD_DIR" && $APPTAINER build "$CACHED_SIF" "$DEF_FILE") || {
        echo "ERROR: SIF build failed."
        exit 1
    }
fi
SIF_PATH="$CACHED_SIF"

echo "=== Sequential Evaluation (Apptainer) ==="
echo "Result dir: $RESULT_DIR"
echo "Graphs: $GRAPHS"
echo "Neo4j info: $NEO4J_INFO"
echo "Threads per graph: $NUM_THREADS"
echo "Instance wait timeout: ${TIMEOUT}s"
echo ""

FAILED_GRAPHS=""

for GRAPH in $GRAPHS; do
    echo "=========================================="
    echo "[$(date '+%H:%M:%S')] Processing graph: $GRAPH"
    echo "=========================================="

    # Get port and instance name from neo4j_info
    GRAPH_INFO=$(python3 -c "
import json
info = json.loads('$NEO4J_INFO_DATA')
for domain in info.get('test_domains', []) + info.get('train_domains', []):
    d = info[domain]
    if domain == '$GRAPH':
        print(f\"{d['port']}|{d['host']}\")
        break
")
    PORT="${GRAPH_INFO%%|*}"
    HOST="${GRAPH_INFO##*|}"

    INSTANCE="cypherbench-${GRAPH//_/-}"

    # Check if the instance is already running
    if $APPTAINER instance list 2>/dev/null | grep -q "$INSTANCE"; then
        echo "Instance $INSTANCE is already running, using it as-is."
    else
        graph_json="$PROJECT_DIR/benchmark/graphs/simplekg/${GRAPH}_simplekg.json"
        if [ ! -f "$graph_json" ]; then
            echo "ERROR: Graph file not found at $graph_json"
            FAILED_GRAPHS="$FAILED_GRAPHS $GRAPH"
            continue
        fi

        echo "Starting instance $INSTANCE on port $PORT..."
        inst_dir="$PROJECT_DIR/.cache/neo4j-instances/$INSTANCE"
        mkdir -p "$inst_dir"/{data,logs,run,plugins}
        $APPTAINER instance start \
            --bind "$graph_json:/init/graph.json" \
            --bind "$inst_dir/data:/var/lib/neo4j/data" \
            --bind "$inst_dir/logs:/var/log/neo4j" \
            --bind "$inst_dir/run:/var/lib/neo4j/run" \
            --bind "$inst_dir/plugins:/var/lib/neo4j/plugins" \
            --env "NEO4J_AUTH=$NEO4J_USERNAME/$NEO4J_PASSWORD" \
            --env "NEO4J_PLUGINS=[\"apoc\",\"graph-data-science\"]" \
            --env "NEO4J_server_bolt_listen__address=:$PORT" \
            --env "NEO4J_server_bolt_advertised__address=:$PORT" \
            "$SIF_PATH" \
            "$INSTANCE" || {
            echo "ERROR: Failed to start $INSTANCE"
            FAILED_GRAPHS="$FAILED_GRAPHS $GRAPH"
            continue
        }
    fi

    # Wait for Neo4j to be ready
    echo "Waiting for $GRAPH to be ready..."
    python3 "$PROJECT_DIR/scripts/wait_for_graph.py" \
        --graph "$GRAPH" \
        --neo4j_info "$NEO4J_INFO" \
        --timeout "$TIMEOUT" || {
        echo "ERROR: $GRAPH did not become ready within ${TIMEOUT}s"
        echo "Stopping instance $INSTANCE..."
        $APPTAINER instance stop "$INSTANCE" 2>/dev/null || true
        FAILED_GRAPHS="$FAILED_GRAPHS $GRAPH"
        continue
    }

    # Run evaluation for this graph
    echo "Running evaluation for $GRAPH..."
    python3 -m cypherbench.evaluate \
        --result_dir "$RESULT_DIR" \
        --neo4j_info "$NEO4J_INFO" \
        --num_threads "$NUM_THREADS" \
        --graph "$GRAPH" || {
        echo "ERROR: Evaluation failed for $GRAPH"
        FAILED_GRAPHS="$FAILED_GRAPHS $GRAPH"
    }

    # Stop the instance after evaluation
    echo "Stopping instance $INSTANCE..."
    $APPTAINER instance stop "$INSTANCE" 2>/dev/null || true

    echo ""
done

echo "=========================================="
echo "[$(date '+%H:%M:%S')] All graphs processed."
echo "=========================================="

# Merge per-graph results
echo ""
echo "Merging per-graph results..."
python3 "$PROJECT_DIR/scripts/merge_eval_results.py" \
    --result_dir "$RESULT_DIR" \
    --graphs $GRAPHS || {
    echo "ERROR: Failed to merge results"
}

if [ -n "$FAILED_GRAPHS" ]; then
    echo ""
    echo "WARNING: The following graphs had errors:$FAILED_GRAPHS"
fi

echo ""
echo "Done! Results saved to $RESULT_DIR/result_with_metrics.json"
echo "Aggregated metrics: $RESULT_DIR/aggregated_metrics.json"
