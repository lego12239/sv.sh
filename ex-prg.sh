#!/bin/bash

_hdl_sig()
{
	echo "Got some signal. Ignore. " >&2
	return 0
}

trap _hdl_sig SIGTERM SIGINT SIGQUIT SIGHUP

echo "I'm started"
echo "test stderr" >&2

while true; do
	echo "`date` some info"
	sleep 1s
done
