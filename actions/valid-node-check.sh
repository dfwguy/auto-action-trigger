#!/bin/bash
#
# BCM health-check script: reports 'fail' the first time it runs on a node and
# 'pass' on every run after, using /tmp/PASS as the marker. /tmp is node-local
# and cleared on boot, so this reads as "this node has been seen since it came
# up".
#
## No category gate. Nothing in this tree sets CMD_CATEGORY -- the only
## registration that would is the commented example at the bottom of
## pre-post/create-action-trigger.sh -- so testing it here means the check
## reports 'fail' on every node forever. A site that does use BCM categories
## adds the filter at registration time (that example shows how), which is the
## right place for it: the check then simply never runs on nodes outside the
## category, instead of running and failing them.

if [[ ! -s /tmp/PASS ]]; then
	echo pass > /tmp/PASS
	echo fail
else
	echo pass
fi
