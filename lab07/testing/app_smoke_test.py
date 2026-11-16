#!/usr/bin/env python3
"""Smoke test for the Terraform Weather Advisor deployment."""

import argparse
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def terraform_outputs(folder):
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=folder,
        capture_output=True,
        text=True,
        check=True
    )
    return {
        name: item["value"]
        for name, item in json.loads(result.stdout).items()
    }


def get(url, timeout=30):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body, status = resp.read().decode(), resp.status
    except urllib.error.HTTPError as err:
        body, status = err.read().decode(), err.code
    except (urllib.error.URLError, TimeoutError) as err:
        return 0, {"error": f"no connection: {err}"}

    try:
        return status, json.loads(body)
    except ValueError:
        return status, body


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zip", default="60616")
    parser.add_argument("--weather-url")
    parser.add_argument("--advisor-url")
    args = parser.parse_args()

    if args.weather_url and args.advisor_url:
        weather, advisor = args.weather_url, args.advisor_url
    else:
        outputs = terraform_outputs(
            Path(__file__).resolve().parent.parent
        )
        weather = outputs["weather_url"]
        advisor = outputs["advisor_url"]

    results = []

    def check(name, ok, detail=""):
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'}   {name}   {detail}")

    # 1. Weather forecast
    status, body = get(f"{weather}/weather?zip={args.zip}")
    check(
        "weather tier returns a forecast",
        status == 200 and isinstance(body, dict) and "forecast" in body,
        f"status {status}"
    )

    # 2. DynamoDB cache
    status, body = get(f"{weather}/weather?zip={args.zip}")
    cache = body.get("cache") if isinstance(body, dict) else None
    check(
        "repeat request is served from DynamoDB",
        status == 200 and cache == "hit",
        f"cache={cache}"
    )

    # 3. Weather history
    status, body = get(f"{weather}/history")
    count = body.get("count", 0) if isinstance(body, dict) else 0
    check(
        "history contains saved lookups",
        status == 200 and count >= 1,
        f"status {status}, count={count}"
    )

    # 4. Invalid ZIP
    status, body = get(f"{weather}/weather?zip=abc")
    check("weather rejects invalid ZIP", status == 400, f"status {status}")

    # 5. Unknown ZIP
    status, body = get(f"{weather}/weather?zip=00000")
    check("weather rejects unknown ZIP", status == 404, f"status {status}")

    # 6. Advisor recommendation
    started = time.time()
    status, body = get(f"{advisor}/advice?zip={args.zip}")
    ok = status == 200 and isinstance(body, dict) and bool(body.get("advice"))
    check(
        "advisor returns clothing advice",
        ok,
        f"status {status}, {time.time() - started:.1f}s"
    )

    # 7. Gemini source
    source = body.get("source") if isinstance(body, dict) else None
    check(
        "advice comes from Gemini",
        source == "gemini",
        f"source={source}"
    )

    # 8. Advisor invalid ZIP
    status, body = get(f"{advisor}/advice?zip=abc")
    check("advisor rejects invalid ZIP", status == 400, f"status {status}")

    # 9. Advisor homepage
    status, body = get(f"{advisor}/")
    check(
        "advisor homepage loads",
        status == 200 and isinstance(body, str) and "<form" in body,
        f"status {status}"
    )

    print(f"\n{sum(results)} of {len(results)} checks passed")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
