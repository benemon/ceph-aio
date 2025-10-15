#!/bin/bash
set -e

# Run bootstrap if needed
/bootstrap.sh

# Start supervisord (runs in foreground due to nodaemon=true)
exec /usr/bin/supervisord -c /etc/supervisord.conf
