#!/bin/bash

echo "test stderr" >&2
echo "test stdout"

running=1
while [[ "$running" ]]; do
	sleep 1s
	while read -t0 line; do
		read line
		if [[ -z "$line" ]]; then
			break
		fi
		case $line in
		"ping "*)
			reply="ok $line"
			;;
		exit)
			reply="ok exit"
			running=
			;;
		*)
			reply="err unknown command"
			;;
		esac
		echo $reply
	done
# some work here
done
