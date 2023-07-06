#!/bin/bash
# Copyright (c) 2023 Oleg Nemanov <lego12239@yandex.ru>
# Version 0.11
# SPDX-License-Identifier: BSD-2-Clause
# Dependencies: sleep, date, rm, sed, setsid, head, tail, kill, logger, stat

set -u

# Delay between child restarts.
SV_RESTART_DELAY=${RESTART_DELAY:-2s}
# Log to files is actived only if SV_SYSLOG is empty.
SV_LOGPATH=${SV_LOGPATH:-}
# Directory for pid file with our pid.
SV_PIDPATH=${SV_PIDPATH:-}
# A maximum count of sv log files.
SV_LOGFILES_CNT=${SV_LOGFILES_CNT:-30}
# Maximum size(in bytes) of child log file for log reopening.
SV_PRG_LOGFILE_MAXSIZE=${SV_PRG_LOGFILE_MAXSIZE:-10000000}
# A maximum count of child log files.
SV_PRG_LOGFILE_MAXCNT=${SV_PRG_LOGFILE_MAXCNT:-3}
# The value is a syslog priority (facility.level). See logger(1).
# If value is not empty, then loggin to files is disabled.
# E.g. "user.notice".
SV_SYSLOG=${SV_SYSLOG:-}
# How we terminate a child.
# A sequence of "SIGNAL/TIME_TO_WAIT" separated with /.
SV_KILLSEQ=${SV_KILLSEQ:-TERM/2s/TERM/4s}

info_out()
{
	if [[ "$SV_SYSLOG" ]]; then
		echo "$@"
	else
		echo "`date +'%F %T'` $@"
	fi
}

err_out()
{
	if [[ "$SV_SYSLOG" ]]; then
		echo "$@" >&2
	else
		echo "`date +'%F %T'` $@" >&2
	fi
}

err_exit()
{
	err_out "$@"
	exit 1
}

get_abspath()
{
	local p

	p="$1"
	if [[ "$p" = "." ]] || [[ "$p" = ".." ]] || [[ "$p" != "${p#./}" ]] ||
	   [[ "$p" != "${p#../}" ]]; then
		p="$PWD/$p"
	fi

	echo "$p"
}

_hdl_exit()
{
	if [[ "$SV_PIDPATH" ]]; then
		rm "$SV_PIDPATH/$PRGTAG.pid"
	fi
	kill -TERM -$$
}

_hdl_sig()
{
	info_out "Got $1"
	RUNNING=
}

hdl_sigterm()
{
	_hdl_sig SIGTERM
}

hdl_sigint()
{
	_hdl_sig SIGINT
}

hdl_sigquit()
{
	_hdl_sig SIGQUIT
}

hdl_sighup()
{
#	_hdl_sig SIGHUP
	RESTART=1
}

is_child_running()
{
	local ret

	ret=`jobs  | sed -nre '/^[^[:space:]]+[[:space:]]+(Running|Stopped)[[:space:]]/ p;'`
	[[ "$ret" ]] && return 0
	return 1
}

child_kill()
{
	local SIG cnt kseq

	kseq="$SV_KILLSEQ/"
	while is_child_running && [[ "${kseq}" ]]; do
		SIG=${kseq%%/*}
		kseq=${kseq#*/}
		info_out "Sending SIG$SIG to a child..."
		kill -$SIG %1
		sleep ${kseq%%/*}
		kseq=${kseq#*/}
	done
	if is_child_running; then
		info_out "Child isn't terminated - sending SIGKILL to a child..."
		kill -KILL %1
		cnt=""
		while is_child_running && [[ $cnt != "..." ]]; do
			cnt="${cnt}."
			sleep 2s
		done
	fi

	if is_child_running; then
		err_exit "Child isn't terminated after SIGKILL - may be it waiting IO"
	fi
}

rm_old_logs()
{
	local fname

	ls -1 "${1}"* | head -n-$2 |
	  while read fname; do
		echo rm $fname
	done
}

reopen_logs()
{
	local LOG_POSTFIX LOG_SIZE RESTART

	if [[ "$SV_SYSLOG" ]] || [[ -z "$SV_LOGPATH" ]]; then
		return
	fi

	RESTART=
	LOG_POSTFIX=`mk_log_postfix`
	exec >>"$SV_LOGPATH/$PRGTAG.sv.log-$LOG_POSTFIX" 2>>"$SV_LOGPATH/$PRGTAG.sv.err.log-$LOG_POSTFIX"
	rm_old_logs "$SV_LOGPATH/$PRGTAG.sv.log" $SV_LOGFILES_CNT
	rm_old_logs "$SV_LOGPATH/$PRGTAG.sv.err.log" $SV_LOGFILES_CNT
	LOG_SIZE=$(stat -c%s $(ls -1 "$SV_LOGPATH/$PRGTAG.log"-* | tail -n1))
	if [[ "$LOG_SIZE" -ge "$SV_PRG_LOGFILE_MAXSIZE" ]]; then
		RESTART=1
	else
		LOG_SIZE=$(stat -c%s $(ls -1 "$SV_LOGPATH/$PRGTAG.err.log"-* | tail -n1))
		if [[ "$LOG_SIZE" -ge "$SV_PRG_LOGFILE_MAXSIZE" ]]; then
			RESTART=1
		fi
	fi
	if [[ "$RESTART" ]]; then
		info_out "Stop a child for log reopening..."
		child_kill
		rm_old_logs "$SV_LOGPATH/$PRGTAG.log" $SV_PRG_LOGFILE_MAXCNT
		rm_old_logs "$SV_LOGPATH/$PRGTAG.err.log" $SV_PRG_LOGFILE_MAXCNT
	fi
}

mk_log_postfix()
{
	echo `date +'%Y%m%d-%T'`
}

show_usage()
{
	echo "Usage: `basename $0` TAG BIN_FULLPATH BIN_ARG1 ..."
	echo "  Where:"
	echo "    TAG           - prefix for log and pid files (no '-' at start)"
	echo "    BIN_FULLPATH  - a full path of binary to supervise"
	echo "    BIN_ARG1, etc - a cmd args for binary"
}

show_version()
{
	echo "Version 0.11"
}

case "$1" in
-h|--help|help)
	show_usage
	exit
	;;
-v|--version)
	show_version
	exit
	;;
-SUPERVISE)
	shift
	PRGTAG=$1
	shift
	;;
-*)
	err_exit "Wrong option: $1"
	exit 1
	;;
*)
	PRGTAG=$1
	shift
	BINPATH=`get_abspath "$1"`
	shift
	setsid $0 -SUPERVISE $PRGTAG "$BINPATH" "$@" &
	exit
	;;
esac

if [[ "$SV_PIDPATH" ]] && [[ ! -e "$SV_PIDPATH" ]]; then
	mkdir -p "$SV_PIDPATH" ||
	  err_exit "Can't create pid directory"
fi
if [[ "$SV_PIDPATH" ]]; then
	echo $$ > "$SV_PIDPATH/$PRGTAG.pid"
fi
LOG_POSTFIX=`mk_log_postfix`
cd /
if [[ "$SV_SYSLOG" ]]; then
	exec > >(logger -t "$PRGTAG") 2>&1
else
	if [[ "$SV_LOGPATH" ]]; then
		if [[ ! -e "$SV_LOGPATH" ]]; then
			mkdir -p "$SV_LOGPATH" ||
			  err_exit "Can't create log directory"
		fi
		exec >>"$SV_LOGPATH/$PRGTAG.sv.log-$LOG_POSTFIX" 2>>"$SV_LOGPATH/$PRGTAG.sv.err.log-$LOG_POSTFIX"
	fi
fi

trap hdl_sigterm SIGTERM
trap hdl_sigint SIGINT
trap hdl_sigquit SIGQUIT
trap hdl_sighup SIGHUP
trap _hdl_exit EXIT

RUNNING=1
RESTART=
while [[ "$RUNNING" ]]; do
	if ! is_child_running; then
		info_out "Child is not running. Starting..."
		if [[ "$SV_SYSLOG" ]] || [[ -z "$SV_LOGPATH" ]]; then
			"$@" &
		else
			"$@" >>"$SV_LOGPATH/$PRGTAG.log-$LOG_POSTFIX" 2>>"$SV_LOGPATH/$PRGTAG.err.log-$LOG_POSTFIX" &
		fi
		PRGPID=$!
		info_out "Child is started: pid=$PRGPID"
	fi
	wait %1
	info_out "Got some signal"
	if [[ "$RUNNING" ]]; then
		sleep $SV_RESTART_DELAY
	fi
	if [[ "$RESTART" ]]; then
		info_out "Got SIGHUP"
		RESTART=
		if [[ -z "$SV_SYSLOG" ]]; then
			info_out "Reopen sv log files"
			reopen_logs
		fi
	fi
done

info_out "Exiting..."
child_kill
