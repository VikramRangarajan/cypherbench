#!/bin/bash
# Stop all sampled Neo4j Apptainer instances.

APPTAINER=$(command -v apptainer || command -v singularity)
if [ -z "$APPTAINER" ]; then
    echo "Error: Neither apptainer nor singularity found."
    exit 1
fi

declare -a graphs=(
    "art"
    "biology"
    "company"
    "fictional_character"
    "flight_accident"
    "geography"
    "movie"
    "nba"
    "politics"
    "soccer"
    "terrorist_attack"
)

echo "Stopping Neo4j instances..."
for graph in "${graphs[@]}"; do
    instance="cypherbench-${graph//_/-}-sampled"
    if $APPTAINER instance list 2>/dev/null | grep -q "$instance"; then
        echo "  Stopping $instance..."
        $APPTAINER instance stop "$instance" 2>/dev/null || true
    else
        echo "  [SKIP] $instance not running"
    fi
done

echo "Done."
