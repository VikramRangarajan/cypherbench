FROM neo4j:5.20.0-community

# Update the package list and install netcat and Python
RUN apt-get update && apt-get install -y --no-install-recommends \
    netcat \
    python3 \
    python3-pip \
 && rm -rf /var/lib/apt/lists/*

# Optionally upgrade pip
RUN python3 -m pip install --no-cache-dir --upgrade pip

# Set the working directory to /var/lib/neo4j (default for Neo4j in Docker)
WORKDIR /var/lib/neo4j

# Copy Python scripts and requirements into the image
COPY requirements.txt ./repo/requirements.txt
COPY scripts/ ./repo/scripts/

# Install any Python dependencies
RUN python3 -m pip install --no-cache-dir -r repo/requirements.txt

RUN chmod +x repo/scripts/entrypoint.sh

# Run our entrypoint, which starts Neo4j via the base-image entrypoint
# and then runs the loader against /init/graph.json
ENTRYPOINT ["repo/scripts/entrypoint.sh"]
CMD ["neo4j"]
