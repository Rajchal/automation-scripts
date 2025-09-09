#!/usr/bin/env python3
"""
Docker Layer Size Analyzer

Shows layer sizes for a local or remote image (pulling if needed) and highlights
layers exceeding a threshold. Supports JSON output and comparison between two tags.

Methods:
  - Uses `docker image inspect` for layer diff IDs & config
  - Uses `docker history --no-trunc --format` to correlate layer sizes

Usage:
  python docker-layer-size-analyzer.py --image alpine:3.19
  python docker-layer-size-analyzer.py --image myrepo/app:latest --threshold-mb 20
  python docker-layer-size-analyzer.py --image myrepo/app:latest --compare myrepo/app:prev --json

Exit codes:
  0 success
  1 docker error / image not found
  2 large layer found (unless --no-fail)
"""
from __future__ import annotations
import argparse
import json
import subprocess
import sys


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def ensure_image(image: str) -> bool:
    cp = run(["docker", "image", "inspect", image])
    if cp.returncode == 0:
        return True
    pull = run(["docker", "pull", image])
    return pull.returncode == 0


def parse_history(image: str):
    # returns list of dict: {id, size_bytes, created_by}
    fmt = '{{.ID}}\t{{.Size}}\t{{.CreatedBy}}'
    cp = run(["docker", "history", "--no-trunc", "--format", fmt, image])
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip())
    layers = []
    for line in cp.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) != 3:
            continue
        _id, size, created_by = parts
        size_bytes = 0
        if size.strip() != "missing":
            # docker history sizes like 5.34MB, 23.1kB
            import re
            m = re.match(r"([0-9.]+)([kMGT]?B)", size.strip())
            if m:
                val, unit = m.groups()
                mult = {'B':1,'kB':1024,'MB':1024**2,'GB':1024**3,'TB':1024**4}.get(unit,1)
                size_bytes = float(val)*mult
        layers.append({'id': _id, 'size_bytes': int(size_bytes), 'created_by': created_by})
    return list(reversed(layers))  # base to top


def analyze(image: str, threshold_mb: float):
    if not ensure_image(image):
        raise RuntimeError(f"Unable to pull/inspect image {image}")
    layers = parse_history(image)
    threshold_bytes = threshold_mb * 1024 * 1024
    flagged = [l for l in layers if l['size_bytes'] >= threshold_bytes]
    total = sum(l['size_bytes'] for l in layers)
    return {
        'image': image,
        'layer_count': len(layers),
        'total_mb': round(total/1024/1024,2),
        'threshold_mb': threshold_mb,
        'flagged': [
            {**l, 'size_mb': round(l['size_bytes']/1024/1024,2)} for l in flagged
        ],
        'layers': [
            {**l, 'size_mb': round(l['size_bytes']/1024/1024,2)} for l in layers
        ]
    }


def compare(report_a, report_b):
    # Simple diff: total size delta & top differing layers by created_by string match
    delta_total = report_b['total_mb'] - report_a['total_mb']
    diff = {
        'base_image': report_a['image'],
        'compare_image': report_b['image'],
        'delta_total_mb': round(delta_total,2),
    }
    return diff


def parse_args():
    ap = argparse.ArgumentParser(description="Analyze Docker image layer sizes")
    ap.add_argument('--image', required=True, help='Image name:tag to inspect')
    ap.add_argument('--threshold-mb', type=float, default=10.0, help='Flag layers >= this size (MB)')
    ap.add_argument('--compare', help='Optional second image to compare total size')
    ap.add_argument('--json', action='store_true', help='JSON output')
    ap.add_argument('--no-fail', action='store_true', help='Do not exit non-zero if large layers found')
    return ap.parse_args()


def main():
    args = parse_args()
    try:
        report = analyze(args.image, args.threshold_mb)
        diff = None
        if args.compare:
            comp = analyze(args.compare, args.threshold_mb)
            diff = compare(report, comp)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

    if args.json:
        out = {'report': report}
        if diff:
            out['compare'] = diff
        print(json.dumps(out, indent=2))
    else:
        print(f"Image: {report['image']} total={report['total_mb']}MB layers={report['layer_count']}")
        if diff:
            sign = '+' if diff['delta_total_mb'] >=0 else ''
            print(f"Compare: {diff['compare_image']} delta_total={sign}{diff['delta_total_mb']}MB from {diff['base_image']}")
        if report['flagged']:
            print('Large layers:')
            for l in report['flagged']:
                print(f"  {l['size_mb']}MB {l['created_by'][:80]}")
        else:
            print('No layers exceed threshold.')
    if report['flagged'] and not args.no_fail:
        sys.exit(2)


if __name__ == '__main__':
    main()
