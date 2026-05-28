import argparse
import json
import time
import sys
from cypherbench.neo4j_connector import Neo4jConnector


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--graph', required=True)
    parser.add_argument('--neo4j_info', default='neo4j_info.json')
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--interval', type=int, default=5)
    args = parser.parse_args()

    with open(args.neo4j_info) as fin:
        neo4j_info = json.load(fin)

    conn_info = neo4j_info['full'][args.graph]
    t0 = time.time()

    while time.time() - t0 < args.timeout:
        try:
            conn = Neo4jConnector(name=args.graph, **conn_info)
            rels = conn.get_num_relations()
            print(f'Connected to {args.graph} ({conn_info["host"]}:{conn_info["port"]}): {rels} relations')
            sys.exit(0)
        except Exception as e:
            elapsed = int(time.time() - t0)
            print(f'[{elapsed}s] Waiting for {args.graph} to be ready... {e}')
            time.sleep(args.interval)

    print(f'Timeout ({args.timeout}s) reached for {args.graph}')
    sys.exit(1)


if __name__ == '__main__':
    main()
