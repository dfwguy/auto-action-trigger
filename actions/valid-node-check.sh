#!/bin/bash
#
# BCM health check: 'fail' on the first run since boot, 'pass' after. /tmp is
# node-local and cleared on boot, so the marker means "seen since it came up".
# Category filtering belongs at registration time, not here -- see the commented
# example at the bottom of pre-post/create-action-trigger.sh.

if [[ ! -s /tmp/PASS ]]; then
	echo pass > /tmp/PASS
	echo fail
else
	echo pass
fi
