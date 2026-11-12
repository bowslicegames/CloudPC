#!/usr/bin/env bash
set -e
curl -fsS "http://127.0.0.1:${NOVNC_PORT:-8080}/" >/dev/null
xdpyinfo -display :0 >/dev/null 2>&1
