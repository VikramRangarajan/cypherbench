# neo4j-with-loader

A custom Neo4j 5.20 community Docker image that, on startup, loads a property graph
from a DBMS-independent JSON file mounted at `/init/graph.json`. It mimics the
behaviour of the public `megagonlabs/neo4j-with-loader:2.4` image (used by
[CypherBench](https://github.com/megagonlabs/cypherbench)).

## Source availability

`megagonlabs/neo4j-with-loader` is **not** shipped with public source: the
`megagonlabs/graph_db` and `megagonlabs/pgbench` repos it was built from are
private. The image can be inspected, however, and the loader that lives inside
it (`/var/lib/neo4j/repo/scripts/{loader,schema,entrypoint}.py`) is reproduced
verbatim in this directory. The Dockerfile here is a clean rewrite that
builds the same image from the local sources.

## How it works

1. `scripts/entrypoint.sh` starts Neo4j in the background via the base image's
   `tini -g -- /startup/docker-entrypoint.sh ...` and waits for port 7474.
2. Once Neo4j is reachable, it runs `python3 repo/scripts/loader.py
   --input_path /init/graph.json`.
3. `loader.py` validates the file against the `SimpleKG` (or `WikidataKG`)
   Pydantic model in `schema.py`, then bulk-loads the graph into Neo4j using
   batched `UNWIND ... CREATE` queries. It also creates indexes on every
   entity id, name, and declared property.

## JSON format

Top-level keys:

```json
{
  "schema": {
    "name": "<graph name>",
    "entities":  [ { "label": "Team", "description": null, "properties": { ... } }, ... ],
    "relations": [ { "label": "playsFor", "subj_label": "Player", "obj_label": "Team", "properties": { ... } }, ... ]
  },
  "entities":  [ { "eid": "Team#Q121783", "label": "Team", "name": "...", "aliases": [...], "description": "...", "properties": { ... }, "provenance": [...] }, ... ],
  "relations": [ { "rid": "0", "label": "playsFor", "subj_id": "Player#...", "obj_id": "Team#...", "properties": { ... }, "provenance": [] }, ... ]
}
```

Property datatypes: `int`, `float`, `str`, `bool`, `date`, `list[int]`, `list[float]`, `list[str]`, `list[date]`.

## Build

```bash
docker build -t neo4j-with-loader:local .
```

## Run

```bash
docker run -d \
  --name cypherbench-nba \
  -p 17687:7687 \
  -p 17474:7474 \
  -v $(pwd)/../benchmark/graphs/simplekg/nba_simplekg.json:/init/graph.json \
  -e NEO4J_AUTH=neo4j/cypherbench \
  -e NEO4J_PLUGINS='["apoc", "graph-data-science"]' \
  neo4j-with-loader:local
```

The image is a drop-in replacement for `megagonlabs/neo4j-with-loader:2.4`
in the existing `docker-compose-*.yml` files.
