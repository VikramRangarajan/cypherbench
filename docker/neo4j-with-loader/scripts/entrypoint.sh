#!/bin/bash
set -e

# Signal handler for clean shutdown — forwards signals to Neo4j child process.
# Required for Apptainer/Singularity where the entrypoint is PID 1 and must
# explicitly forward signals.
cleanup() {
    echo "Shutting down Neo4j..."
    kill "$NEO4J_PID" 2>/dev/null || true
    wait "$NEO4J_PID" 2>/dev/null || true
}
trap cleanup SIGTERM SIGINT SIGQUIT

# Start Neo4j via the base image entrypoint (handles config, plugins, auth, etc.)
/startup/docker-entrypoint.sh "$@" &
NEO4J_PID=$!

# Wait for the Neo4j HTTP API to become available
echo "Waiting for Neo4j to start..."
while ! nc -z localhost 7474 2>/dev/null; do
    sleep 2
done
echo "Neo4j has started."

# Run the data loader if a graph file was mounted at /init/graph.json
if [ -f /init/graph.json ]; then
    echo "Loading data from /init/graph.json..."
    python3 repo/scripts/loader.py --input_path /init/graph.json
    echo "Data loading complete."
else
    echo "No graph file at /init/graph.json — skipping loader."
fi

# Keep Neo4j running in the foreground (blocks until Neo4j exits)
wait "$NEO4J_PID"
