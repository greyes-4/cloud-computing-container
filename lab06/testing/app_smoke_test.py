#!/usr/bin/env python3
"""Test both weather and advisor services through the ALB."""
import json
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path

def load_env(path):
    result = {}
    for line in Path(path).read_text().splitlines():
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.split("=", 1)
            result[k.strip()] = v.strip().strip('"').strip("'")
    return result

env = load_env(".env")
stack = load_env("stack_outputs.env")
alb = stack["ALB_DNS_NAME"]

weather = f"http://{alb}:{env['WEATHER_LISTENER_PORT']}"
advisor = f"http://{alb}:{env['ADVISOR_LISTENER_PORT']}"
results = []

def get(url):
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            status = response.status
            body = response.read().decode()
    except urllib.error.HTTPError as error:
        status = error.code
        body = error.read().decode()
    except Exception as error:
        return 0, {"error": str(error)}
    try:
        return status, json.loads(body)
    except ValueError:
        return status, body

def check(name, condition, detail=""):
    results.append(bool(condition))
    print(f"{'PASS' if condition else 'FAIL'}  {name}  {detail}")

status, body = get(f"{weather}/weather?zip=60616")
check("Weather returns forecast", status == 200 and isinstance(body, dict) and "forecast" in body)

status, body = get(f"{weather}/weather?zip=60616")
check("Database cache hit", status == 200 and isinstance(body, dict) and body.get("cache") == "hit")

status, body = get(f"{weather}/history")
check("Saved lookup history", status == 200 and isinstance(body, dict) and body.get("count", 0) >= 1)

status, body = get(f"{weather}/weather?zip=abc")
check("Weather rejects invalid ZIP", status == 400)

status, body = get(f"{weather}/weather?zip=00000")
check("Weather rejects unknown ZIP", status == 404)

start = time.time()
status, body = get(f"{advisor}/advice?zip=60616")
ok = status == 200 and isinstance(body, dict) and bool(body.get("advice"))
check("Advisor returns advice", ok, f"{time.time()-start:.1f}s")
if ok:
    print(f"      source={body.get('source')} model={body.get('model')}")
    check("Advice comes from Gemini", body.get("source") == "gemini")
else:
    check("Advice comes from Gemini", False)

status, body = get(f"{advisor}/advice?zip=abc")
check("Advisor rejects invalid ZIP", status == 400)

status, body = get(f"{advisor}/")
check("Advisor home page loads", status == 200 and isinstance(body, str) and "<form" in body)

print(f"\n{sum(results)} of {len(results)} checks passed")
sys.exit(0 if all(results) else 1)
