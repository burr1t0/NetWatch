#!/bin/bash
# Redraws the README animations (docs/*.gif) from synthetic data. No screen recording is involved,
# so nothing about a real network can end up in them.
set -euo pipefail

cd "$(dirname "$0")/.."
swift run -c release netwatch-gif docs
