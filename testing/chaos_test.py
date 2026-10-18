#!/usr/bin/env python3
"""Measure application recovery after terminating an ASG instance."""

import argparse
import csv
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from aws_helpers import get_inservice_instance_id, terminate_instance_via_asg
from http_probe import probe_once

PROJECT_DIR = Path(__file__).resolve().parent.parent


def load_env(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def main():
    parser = argparse.ArgumentParser(
        description="Measure recovery after terminating an ASG instance."
    )
    parser.add_argument("--tier", choices=["uploader", "viewer"], required=True)
    parser.add_argument("--slo-seconds", type=float, default=None)
    parser.add_argument("--poll-interval", type=float, default=2.0)
    parser.add_argument("--max-wait", type=float, default=600.0)
    args = parser.parse_args()

    env = {
        **load_env(PROJECT_DIR / ".env"),
        **load_env(PROJECT_DIR / "stack_outputs.env"),
    }

    region = env.get("AWS_REGION", "us-east-2")
    alb_dns = env.get("ALB_DNS_NAME")

    if not alb_dns:
        sys.exit("ALB_DNS_NAME missing. Deploy the stack first.")

    slo_seconds = (
        args.slo_seconds
        if args.slo_seconds is not None
        else float(env.get("RECOVERY_SLO_SECONDS", "180"))
    )

    if args.tier == "uploader":
        port = env.get("UPLOADER_LISTENER_PORT", "8080")
        asg_name = env.get("UPLOADER_ASG_NAME")
    else:
        port = env.get("VIEWER_LISTENER_PORT", "8081")
        asg_name = env.get("VIEWER_ASG_NAME")

    url = f"http://{alb_dns}:{port}/"

    print(f"Target: {args.tier} tier at {url}", flush=True)
    print("Confirming the endpoint is healthy...", flush=True)

    if not probe_once(url):
        sys.exit("Endpoint is not responding. Fix it before testing.")

    instance_id = get_inservice_instance_id(asg_name, region)

    if not instance_id:
        sys.exit(f"No InService instance found in {asg_name}.")

    print(f"Terminating {instance_id} via the Auto Scaling Group...", flush=True)

    log_rows = []
    t0 = time.monotonic()

    terminate_instance_via_asg(instance_id, region)

    print("Polling the endpoint for downtime and recovery...", flush=True)

    down_at = None
    recovered_at = None

    while True:
        elapsed = time.monotonic() - t0

        if elapsed > args.max_wait:
            break

        is_up = probe_once(url)
        elapsed = time.monotonic() - t0

        log_rows.append((round(elapsed, 2), is_up))

        if down_at is None and not is_up:
            down_at = elapsed
            print(f"Endpoint DOWN at {down_at:.1f}s", flush=True)

        elif down_at is not None and is_up:
            recovered_at = elapsed
            print(f"Endpoint UP at {recovered_at:.1f}s", flush=True)
            break

        time.sleep(args.poll_interval)

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    log_path = PROJECT_DIR / "testing" / f"chaos_test_{args.tier}_{timestamp}.csv"

    with open(log_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["elapsed_seconds", "is_up"])
        writer.writerows(log_rows)

    print(f"Poll log written to {log_path}", flush=True)

    if down_at is None:
        print("INCONCLUSIVE: no outage was detected.", flush=True)
        sys.exit(2)

    if recovered_at is None:
        print(f"FAIL: no recovery within {args.max_wait:.0f}s.", flush=True)
        sys.exit(1)

    print(
        f"Recovery time: {recovered_at:.1f}s "
        f"(SLO: {slo_seconds:.0f}s)",
        flush=True,
    )
    print(f"Detected downtime: {recovered_at - down_at:.1f}s", flush=True)

    if recovered_at <= slo_seconds:
        print("PASS: recovery time met the SLO.", flush=True)
        sys.exit(0)
    else:
        print("FAIL: recovery time exceeded the SLO.", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
