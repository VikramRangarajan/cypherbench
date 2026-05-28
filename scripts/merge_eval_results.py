import argparse
import json
import os
import math
from cypherbench.schema import Nl2CypherSample

RETURN_PATTERN_MAPPING = {
    "n_name": "n_name",
    "n_prop": "n_prop_combined",
    "n_name_prop": "n_prop_combined",
    "n_prop_distinct": "n_prop_combined",
    "n_prop_array_distinct": "n_prop_combined",
    "n_order_by": "n_order_by",
    "n_argmax": "n_argmax",
    "n_where": "n_where",
    "n_agg": "n_agg",
    "n_group_by": "n_group_by"
}


def avg_and_round(nums: list[float], n: int = 4):
    return round(sum(nums) / len(nums), n) if nums else math.nan


def aggregate(results: list[tuple[str, float]]):
    res = {}
    for key, value in results:
        if key not in res:
            res[key] = []
        res[key].append(value)
    for key, values in res.items():
        res[key] = avg_and_round(values)
    return res


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--result_dir', required=True)
    parser.add_argument('--graphs', nargs='+', required=True)
    parser.add_argument('--metrics', nargs='+', default=['execution_accuracy', 'psjs', 'executable'])
    parser.add_argument('--metric_for_agg', default='execution_accuracy')
    args = parser.parse_args()

    all_items = []
    for graph in args.graphs:
        path = os.path.join(args.result_dir, f'result_with_metrics_{graph}.json')
        if not os.path.exists(path):
            print(f'Warning: {path} not found, skipping {graph}')
            continue
        with open(path) as fin:
            items = [Nl2CypherSample(**item) for item in json.load(fin)]
        all_items.extend(items)
        print(f'Loaded {len(items)} results from {graph}')

    if not all_items:
        print('No results loaded. Exiting.')
        return

    with open(os.path.join(args.result_dir, 'result_with_metrics.json'), 'w') as fout:
        json.dump([item.model_dump(mode='json') for item in all_items], fout, indent=2)

    aggregated = {}
    aggregated['overall'] = {m: avg_and_round([item.metrics[m] for item in all_items]) for m in args.metrics}

    metric_for_agg = args.metric_for_agg
    aggregated['by_graph'] = aggregate([(item.graph, item.metrics[metric_for_agg]) for item in all_items])
    aggregated['by_match'] = aggregate([(item.from_template.match_category, item.metrics[metric_for_agg])
                                        for item in all_items])
    aggregated['by_return'] = aggregate(
        [(RETURN_PATTERN_MAPPING[item.from_template.return_pattern_id], item.metrics[metric_for_agg])
         for item in all_items if item.from_template.return_pattern_id in RETURN_PATTERN_MAPPING]
    )

    with open(os.path.join(args.result_dir, 'aggregated_metrics.json'), 'w') as fout:
        json.dump(aggregated, fout, indent=2)

    print()
    print('Merged aggregated metrics:')
    print(json.dumps(aggregated, indent=2))


if __name__ == '__main__':
    main()
