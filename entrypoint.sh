#!/bin/bash
set -e

# The image prepares this top-level path; recreate its child defensively
# before writing NSS state or starting supervisord.
mkdir -p /ceph-run/supervisor

# OpenShift assigns an arbitrary UID that is absent from /etc/passwd.
# Supply an NSS identity without modifying the image's passwd database.
uid=$(id -u)
if ! getent passwd "$uid" >/dev/null 2>&1; then
    gid=$(id -g)
    passwd_file="/ceph-run/passwd.$uid"
    group_file="/ceph-run/group.$uid"
    cp /etc/passwd "$passwd_file"
    cp /etc/group "$group_file"
    echo "ceph-aio:x:$uid:$gid:Ceph AIO:/var/lib/ceph:/sbin/nologin" >> "$passwd_file"
    cat > /ceph-run/nss-env <<EOF
export LD_PRELOAD=libnss_wrapper.so
export NSS_WRAPPER_PASSWD=$passwd_file
export NSS_WRAPPER_GROUP=$group_file
EOF
    . /ceph-run/nss-env
fi

# Run bootstrap if needed
/bootstrap.sh

# Start supervisord (runs in foreground due to nodaemon=true)
exec /usr/bin/supervisord -c /etc/supervisord.conf
