#!/bin/bash

. $(dirname "$0")/scylla_util.sh

. "$sysconfdir"/scylla-server


if is_privileged; then
    "$scriptsdir"/scylla_prepare
fi
execsudo /usr/bin/env SCYLLA_HOME=$SCYLLA_HOME SCYLLA_CONF=$SCYLLA_CONF "$bindir"/scylla $SCYLLA_ARGS
