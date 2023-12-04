#!/bin/bash

tag=$1
shift
event=$1
shift
case $event in
"svstart")
	echo "hook: $tag: got $event: $@"
	;;
"svstop")
	echo "hook: $tag: got $event: $@"
	;;
"start")
	echo "hook: $tag: got $event: $@"
	;;
"stop")
	echo "hook: $tag: got $event: $@"
	;;
"usr1")
	echo "hook: $tag: got $event: $@"
	exit 1
	;;
"usr2")
	echo "hook: $tag: got $event: $@"
	;;
*)
	echo "hook: $tag: unknown event: $event $@" >&2
	;;
esac

exit 0
