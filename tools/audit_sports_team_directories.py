"""Capture public team identities for the optional matching directory audit.

Generate the input with `dart run tools/sports_league_inventory.dart`.
The captured directory is diagnostic evidence, never a production alias database.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def capture(league, output):
    destination = output / (league['id'].replace('/', '_') + '.json')
    if destination.exists():
        return json.loads(destination.read_text())
    result = {'league': league, 'teams': []}
    if league['kind'] != 'team' or league['source'] != 'ESPN':
        result['status'] = 'not-espn-team-directory'
    else:
        url = ('https://site.api.espn.com/apis/site/v2/sports/'
               + league['path'] + '/teams?limit=1000')
        try:
            request = Request(url, headers={'User-Agent': 'Sports matching audit'})
            with urlopen(request, timeout=12) as response:
                body = json.load(response)
            teams = [entry['team'] for sport in body.get('sports', [])
                     for division in sport.get('leagues', [])
                     for entry in division.get('teams', [])]
            fields = ('id', 'name', 'displayName', 'shortDisplayName',
                      'nickname', 'abbreviation', 'location')
            result['teams'] = [{k: t[k] for k in fields if k in t} for t in teams]
            result['status'] = 'ok' if teams else 'empty'
        except HTTPError as error:
            result['status'] = f'http-{error.code}'
        except (URLError, TimeoutError, ValueError, KeyError) as error:
            result['status'] = type(error).__name__
    destination.write_text(json.dumps(result, ensure_ascii=False))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('inventory', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    leagues = json.loads(args.inventory.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=4) as executor:
        result = list(executor.map(lambda league: capture(league, args.output),
                                   leagues))
    (args.output / 'summary.json').write_text(json.dumps(result, ensure_ascii=False))
    print(json.dumps({'directories': dict(Counter(r['status'] for r in result)),
                      'team_records': sum(len(r['teams']) for r in result)}))


if __name__ == '__main__':
    main()
