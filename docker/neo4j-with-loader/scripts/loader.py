from neo4j import GraphDatabase
from neo4j.time import Date
import datetime
import argparse
import os
import collections
from tqdm import trange, tqdm
import json
from schema import *


class BulkNeo4jKGLoader:
    def __init__(self, uri, user, password, database, batch_size=100, overwrite=False):

        self.driver = GraphDatabase.driver(uri, auth=(user, password))
        self.driver.verify_connectivity()
        self.database = database
        self.batch_size = batch_size
        self.overwrite = overwrite

    def close(self):
        self.driver.close()

    @staticmethod
    def _convert_datatypes(properties: dict):
        for k, v in properties.items():
            if isinstance(v, datetime.date):
                properties[k] = Date(v.year, v.month, v.day)
        return properties

    @staticmethod
    def _create_nodes_batch(tx, batch, label):
        query = """
        UNWIND $batch AS row
        CREATE (n:%s)
        SET n += row.properties
        RETURN count(n)
        """ % label
        tx.run(query, batch=batch)

    @staticmethod
    def _create_relations_batch(tx, batch, relation_label, subj_label, obj_label, entity_id_key):
        query = f"""
        UNWIND $batch AS row
        MATCH (startNode:%s), (endNode:%s)
        WHERE startNode.%s = row.start_id AND endNode.%s = row.end_id
        CREATE (startNode)-[r:%s]->(endNode)
        SET r += row.properties
        RETURN count(*) AS rel_count
        """ % (subj_label, obj_label, entity_id_key, entity_id_key, relation_label)
        tx.run(query, batch=batch)

    def load(self, kg: Union[WikidataKG, SimpleKG]):
        # We assume the following keys are used in all KGs
        # - entities:
        #   - name
        #   - label
        #   - properties
        # - relations:
        #   - label
        #   - properties

        if isinstance(kg, WikidataKG):
            entity_id_key = 'wikidata_qid'
            entity_additional_keys = ['description', 'aliases', 'enwiki_title']
            rel_subj_key = 'subj_wikidata_qid'
            rel_obj_key = 'obj_wikidata_qid'
        elif isinstance(kg, SimpleKG):
            entity_id_key = 'eid'
            entity_additional_keys = ['description', 'aliases', 'provenance']
            rel_subj_key = 'subj_id'
            rel_obj_key = 'obj_id'
        else:
            raise ValueError(f'Unsupported KG type: {type(kg)}')

        # 1. Check if the database is empty
        with self.driver.session(database=self.database) as session:
            result = session.run('MATCH (n) RETURN count(n) as count')
            num_nodes = result.single()["count"]
        if num_nodes > 0 and not self.overwrite:
            raise ValueError(
                f"Database {self.database} is not empty. Use --overwrite to delete all data before import.")

        # 2. Delete all constraints, indexes, and data
        with self.driver.session() as session:
            constraints = session.run("SHOW CONSTRAINTS")
            for constraint in constraints:
                constraint_name = constraint["name"]
                drop_command = f"DROP CONSTRAINT {constraint_name}"
                session.run(drop_command)
                print(f"Dropped constraint: {constraint_name}")
            indexes = session.run("SHOW INDEXES")
            for index in indexes:
                index_name = index["name"]
                drop_command = f"DROP INDEX {index_name}"
                session.run(drop_command)
                print(f"Dropped index: {index_name}")
            session.execute_write(lambda tx: tx.run("MATCH (n) DETACH DELETE n"))

        # 3. Load entities
        label2entities = collections.defaultdict(list)
        for e in kg.entities:
            label2entities[e.label].append(e)
        with self.driver.session(database=self.database) as session:
            for label, entities in label2entities.items():
                print(f"Loading {len(entities)} entities with label {label}")
                for i in tqdm(range(0, len(entities), self.batch_size)):
                    batch = [{'properties': dict(
                        name=entity.name,
                        **{k: getattr(entity, k) for k in [entity_id_key] + entity_additional_keys},
                        **self._convert_datatypes(entity.properties))} for entity in entities[i:i + self.batch_size]]
                    session.execute_write(self._create_nodes_batch, batch, label)

        # 4. Create indexes on field wikidata_qid for all entities
        with self.driver.session(database=self.database) as session:
            for label in label2entities.keys():
                index_query = f"CREATE INDEX FOR (n:{label}) ON (n.{entity_id_key})"
                session.run(index_query)
                print(f"Index created for {label}.eid")

        # 5. Load relations
        eid2entity = {getattr(e, entity_id_key): e for e in kg.entities}
        rschemas = {f'{r.label}#{r.subj_label}#{r.obj_label}': r for r in kg.schema.relations}
        schema2relations = collections.defaultdict(list)
        for r in kg.relations:
            subj_label = eid2entity[getattr(r, rel_subj_key)].label
            obj_label = eid2entity[getattr(r, rel_obj_key)].label
            schema2relations[f'{r.label}#{subj_label}#{obj_label}'].append(r)
        with self.driver.session(database=self.database) as session:
            for rschema_str, rschema in rschemas.items():
                relations = schema2relations[rschema_str]
                print(f'Loading {len(relations)} relations with schema {rschema_str}')
                if not relations:
                    continue
                for i in tqdm(range(0, len(relations), self.batch_size)):
                    batch = [{
                        'start_id': getattr(r, rel_subj_key),
                        'end_id': getattr(r, rel_obj_key),
                        'properties': self._convert_datatypes(r.properties)
                    } for r in relations[i:i + self.batch_size]]
                    session.execute_write(self._create_relations_batch, batch, rschema.label,
                                          rschema.subj_label, rschema.obj_label, entity_id_key)

        # 6. Create indexes on all properties
        with self.driver.session(database=self.database) as session:
            for ent in kg.schema.entities:
                if isinstance(kg, WikidataKG):
                    all_props = entity_additional_keys + [p.label for p in ent.properties]
                else:
                    all_props = entity_additional_keys + list(ent.properties.keys())
                for prop in all_props:
                    session.run(f"CREATE INDEX FOR (n:{ent.label}) ON (n.{prop})")
                    print(f"Index created for {ent.label}.{prop}")
            created = set()
            for rel in kg.schema.relations:
                for prop in rel.properties:
                    if isinstance(kg, WikidataKG):
                        prop = prop.label
                    if f'{rel.label}.{prop}' not in created:
                        created.add(f'{rel.label}.{prop}')
                        session.run(f"CREATE INDEX FOR ()-[r:{rel.label}]-() ON (r.{prop})")
                        print(f"Index created for {rel.label}.{prop}")

        print(f'Loaded {len(kg.entities)} entities and {len(kg.relations)} relations')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input_path', default='data/wd2neo4j/entertainment.movie_kg.json',
                        help='Path to the input JSON file')
    parser.add_argument('--uri', default='bolt://localhost:7687', help='URI for Neo4j database')
    parser.add_argument('--database', default='neo4j', help='Name of Neo4j database')
    parser.add_argument('--batch_size', default=500, type=int, help='Batch size for import')
    parser.add_argument('--overwrite', action='store_true', help='Delete all data before import')
    args = parser.parse_args()
    print(args)
    print()

    with open(args.input_path) as f:
        dic = json.load(f)

    kg = None
    for cls in [WikidataKG, SimpleKG]:
        try:
            kg = cls(**dic)
            break
        except Exception as e:
            pass
    if kg is None:
        raise ValueError('Unsupported KG type')

    user, password = os.environ.get('NEO4J_AUTH').split('/')

    loader = BulkNeo4jKGLoader(
        uri=args.uri,
        user=user,
        password=password,
        database=args.database,
        batch_size=args.batch_size,
        overwrite=args.overwrite
    )
    loader.load(kg)
    loader.close()


if __name__ == "__main__":
    main()
