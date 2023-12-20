#!/bin/bash

cd `dirname $0`

case "$1" in
start)
	rm tmp/*

	export SV_PRG_LOGFILE_MAXSIZE=1
	export SV_LOGPATH=tmp
	export SV_PIDPATH=tmp
	export SV_HOOK=./ex-hook.sh
	echo "run prg1 one ./ex-prg.sh" | ./sv.sh env1
	;;
stop)
	if [[ ! -e tmp/env1.pid ]]; then
		echo Already stopped
		exit
	fi
	kill `cat tmp/env1.pid`
	;;
esac
