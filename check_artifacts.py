import sys, json
data=json.load(sys.stdin)
for a in data.get('artifacts', []):
    print(f"{a['id']} {a['name']}")
