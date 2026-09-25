#!/bin/bash
# Double-click in Finder to start the dashboard. Close this window (or Ctrl+C) to stop it.
cd "$(dirname "$0")" || exit 1
exec /usr/bin/env python3 dashboard.py
