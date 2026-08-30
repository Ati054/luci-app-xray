import sys, json
data=json.load(sys.stdin)
for r in data['workflow_runs']:
    print(f"{r['id']} {r['head_sha']} {r['status']} {r['conclusion']}")
