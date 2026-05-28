#!/bin/bash
# Run CypherBench evaluation one graph at a time to limit memory usage.
#
# Usage:
#   bash docker/run_eval_sequential.sh --result_dir output/gpt-4o-mini/ [--graphs ...] [--neo4j_info neo4j_info.json] [--num_threads 1] [--timeout 600]
#
# If --graphs is omitted, all test domains are evaluated.
# Requires: docker-compose, python, and the benchmark graph files in ../benchmark/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RESULT_DIR=""
GRAPHS=""
NEO4J_INFO="$PROJECT_DIR/neo4j_info.json"
NUM_THREADS=1
TIMEOUT=600

while [[ $# -gt 0 ]]; do
    case "$1" in
        --result_dir) RESULT_DIR="$2"; shift 2 ;;
        --graphs) GRAPHS="$2"; shift 2 ;;
        --neo4j_info) NEO4J_INFO="$2"; shift 2 ;;
        --num_threads) NUM_THREADS="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
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

echo "=== Sequential Evaluation ==="
echo "Result dir: $RESULT_DIR"
echo "Graphs: $GRAPHS"
echo "Neo4j info: $NEO4J_INFO"
echo "Threads per graph: $NUM_THREADS"
echo "Container wait timeout: ${TIMEOUT}s"
echo ""

PROJECT_DIR="$PROJECT_DIR"
FAILED_GRAPHS=""

for GRAPH in $GRAPHS; do
    echo "=========================================="
    echo "[$(date '+%H:%M:%S')] Processing graph: $GRAPH"
    echo "=========================================="

    # Determine compose file and project name
    IS_TRAIN=$(python3 -c "
import json
with open('$NEO4J_INFO') as f:
    info = json.load(f)
print('true' if '$GRAPH' in info['train_domains'] else 'false')
")
    if [ "$IS_TRAIN" = "true" ]; then
        COMPOSE_FILE="$SCRIPT_DIR/docker-compose-train.yml"
        PROJECT="cypherbench_train"
    else
        COMPOSE_FILE="$SCRIPT_DIR/docker-compose-test.yml"
        PROJECT="cypherbench_test"
    fi

    SERVICE="cypherbench-${GRAPH//_/-}"

    # Check if the container is already running
    RUNNING=$(docker ps --filter "name=$SERVICE" --format '{{.Names}}' 2>/dev/null || true)
    if [ -n "$RUNNING" ]; then
        echo "Container $SERVICE is already running, using it as-is."
    else
        echo "Starting container $SERVICE..."
        docker-compose -f "$COMPOSE_FILE" -p "$PROJECT" up -d "$SERVICE" || {
            echo "ERROR: Failed to start $SERVICE"
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
        echo "Stopping container $SERVICE..."
        docker-compose -f "$COMPOSE_FILE" -p "$PROJECT" down || true
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

    # Stop the container if we started it
    if [ -z "${RUNNING:-}" ]; then
        echo "Stopping container $SERVICE..."
        docker-compose -f "$COMPOSE_FILE" -p "$PROJECT" down || true
    fi

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
