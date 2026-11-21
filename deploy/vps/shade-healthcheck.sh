#!/bin/bash
# Restart the relay if it is running but no longer answers (hung event loop).
if systemctl is-active --quiet shade; then
  if ! curl -fsS -m 10 http://127.0.0.1:3000/api/health >/dev/null; then
    sleep 20
    if ! curl -fsS -m 10 http://127.0.0.1:3000/api/health >/dev/null; then
      logger -t shade-healthcheck 'health check failed twice, restarting shade'
      systemctl restart shade
    fi
  fi
fi
