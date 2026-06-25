#!/bin/sh
# Diagnostic output before exec-ing bash
echo "=== shell check ==="
echo "which bash: $(which bash 2>/dev/null || echo NOT FOUND)"
ls -la /bin/bash /usr/bin/bash 2>&1
echo "=== exec bash ==="
exec /usr/bin/bash
