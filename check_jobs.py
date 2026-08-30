import sys, json
data=json.load(sys.stdin)
for j in data['jobs']:
    print(f"{j['name']}: {j['status']} {j['conclusion']}")
