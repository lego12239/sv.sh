#!/bin/bash
# Copyright (c) 2023 Oleg Nemanov <lego12239@yandex.ru>
# Version 2.3
# SPDX-License-Identifier: BSD-2-Clause
# Dependencies: bash >=4.3 (for wait -n, process substitution support), sleep, date, rm, sed, setsid, logger, stat

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
SV_PRG_LOGFILES_CNT=${SV_PRG_LOGFILES_CNT:-$SV_LOGFILES_CNT}
# The value is a syslog priority (facility.level). See logger(1).
# If value is not empty, then loggin to files is disabled.
# E.g. "user.notice".
SV_SYSLOG=${SV_SYSLOG:-}
# How we terminate a child.
# A sequence of "SIGNAL/TIME_TO_WAIT" separated with /.
SV_KILLSEQ=${SV_KILLSEQ:-TERM/2s/TERM/4s}
# Set to "no" to not change dir to / after startup.
SV_CHDIR=${SV_CHDIR:-yes}


NL="
"


info_out()
{
	if [[ "$SV_SYSLOG" ]]; then
		echo "SV: $@"
	else
		echo "`date +'%F %T'` $@"
	fi
}

err_out()
{
	if [[ "$SV_SYSLOG" ]]; then
		echo "SV: $@" >&2
	else
		echo "`date +'%F %T'` $@" >&2
	fi
}

err_exit()
{
	err_out "$@"
	exit 1
}

is_true()
{
	case "$1" in
		[Yy][Ee][Ss]|[Tt][Rr][Uu][Ee]|[Oo][Nn]|1)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

mk_abspath()
{
	local p

	p="$1"
	if [[ "${2:-}" = "bin" ]]; then
		if [[ "$p" != "${p#./}" ]] || [[ "$p" != "${p#../}" ]]; then
			p="$PWD/$p"
		fi
	else
		if [[ "$p" = "${p#/}" ]]; then
			p="$PWD/$p"
		fi
	fi

	echo "$p"
}

_hdl_exit()
{
	if [[ "$SV_PIDPATH" ]]; then
		rm "$SV_PIDPATH/$SVTAG.pid"
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

save_cmds()
{
	local act rs tag prg opts tags

	export SV_CMDS=""
	tags=" "
	while read act tag rs prg opts; do
		case "$act" in
		wait)
			SV_CMDS="${SV_CMDS}$act $tag$NL"
			;;
		run)
			if echo "$tags" | grep " $tag " >/dev/null 2>&1; then
				err_exit "Child spec error: tag already used: '$tag'"
			fi
			tags="$tags$tag "
			SV_CMDS="${SV_CMDS}$act $tag $rs `mk_abspath "$prg" bin` $opts$NL"
			;;
		*)
			err_exit "Child spec error: wrong action: '$act'"
			;;
		esac
	done
}

cspec_get()
{
	local cmds cmd act tag

	cmds="$SV_CMDS"
	while [[ "$cmds" ]]; do
		cmd="${cmds%%$NL*}"
		cmds="${cmds#*$NL}"

		act=${cmd%% *}
		cmd=${cmd#* }
		case "$act" in
		run)
			tag=${cmd%% *}

			if [[ "$tag" = "$1" ]]; then
				echo $cmd
				return
			fi
			;;
		esac
	done

	err_exit "cspec_get() error: unknown command tag: '$1'"
}

childs_start()
{
	local ex_wait cmds cmd act tag cpids cpid is_run

	cmds="$SV_CMDS"
	if [[ -z "$CPIDS" ]]; then
		ex_wait=
	else
		ex_wait=1
	fi
	while [[ "$cmds" ]]; do
		cmd="${cmds%%$NL*}"
		cmds="${cmds#*$NL}"

		act=${cmd%% *}
		cmd="${cmd#* }"
		case "$act" in
		wait)
			[[ "$ex_wait" ]] && sleep $cmd
			;;
		run)
			tag=${cmd%% *}
			cmd="${cmd#* }"

			cpids="$CPIDS"
			is_run=
			while [[ "$cpids" ]]; do
				cpid=${cpids%%$NL*}
				cpids="${cpids#*$NL}"
				if [[ "${cpid%% *}" = "$tag" ]]; then
					is_run=1
					break
				fi
			done

			if [[ -z "$is_run" ]]; then
				info_out "Child $tag is not running. Starting..."
				# just remove restart strategy
				cmd="${cmd#* }"
				if [[ "$SV_SYSLOG" ]] || [[ -z "$SV_LOGPATH" ]]; then
					$cmd &
				else
					$cmd >>"$SV_LOGPATH/$SVTAG.$tag.log-$LOG_POSTFIX" 2>>"$SV_LOGPATH/$SVTAG.$tag.err.log-$LOG_POSTFIX" &
				fi
				CPIDS="${CPIDS}$tag $!$NL"
				info_out "Child $tag is started: pid=$!"
			fi
			;;
		*)
			err_exit "Unknown action '$act'"
			;;
		esac
	done
}

childs_cleanup()
{
	local childs child cpids cpid tag cmd cpids_new is_killall is_term is_any_term

	childs=`jobs -l | sed -nre 's/^[^[:space:]]+[[:space:]]+([0-9]+)[[:space:]]+(Running|Stopped)[[:space:]].*$/\1/; T; p;'`
	cpids="$CPIDS"
	cpids_new=""
	is_killall=
	is_any_term=
	while [[ "$cpids" ]]; do
		cpid=${cpids%%$NL*}
		cpids="${cpids#*$NL}"

		tag=${cpid%% *}
		cpid=${cpid#* }
		is_term=1
		for child in $childs; do
			if [[ "$child" = "$cpid" ]]; then
				cpids_new="${cpids_new}$tag $cpid$NL"
				is_term=
			fi
		done
		if [[ "$is_term" ]]; then
			info_out "Child $tag is stopped"
			is_any_term=1
			cmd=`cspec_get $tag`
			# remove a tag
			cmd="${cmd#* }"
			if [[ "${cmd%% *}" = "all" ]]; then
				info_out "Child $tag restart strategy is 'all': stop other children"
				is_killall=1
			fi
		fi
	done

	CPIDS="$cpids_new"
	if [[ "$is_killall" ]]; then
		childs_kill "$CPIDS"
		CPIDS=""
	fi

	if [[ "$is_any_term" ]]; then
		return 0
	fi

	return 1
}

# Do not forget to remove last "E" char from the result.
cpids_cleanup()
{
	local childs child cpids cpid tag cmd cpids_new

	childs=`jobs -l | sed -nre 's/^[^[:space:]]+[[:space:]]+([0-9]+)[[:space:]]+(Running|Stopped)[[:space:]].*$/\1/; T; p;'`
	cpids="$1"
	cpids_new=""
	while [[ "$cpids" ]]; do
		cpid=${cpids%%$NL*}
		cpids="${cpids#*$NL}"

		tag=${cpid%% *}
		cpid=${cpid#* }
		for child in $childs; do
			if [[ "$child" = "$cpid" ]]; then
				cpids_new="${cpids_new}$tag $cpid$NL"
			fi
		done
	done

	# Add E to save a last newline.
	echo -n "${cpids_new}E"
}

childs_kill()
{
	local SIG cnt kseq cpids

	cpids="$1"
	kseq="$SV_KILLSEQ/"
	while [[ "$cpids" ]] && [[ "${kseq}" ]]; do
		SIG=${kseq%%/*}
		kseq=${kseq#*/}
		childs_sendsig "$cpids" $SIG
		sleep ${kseq%%/*}
		cpids=`cpids_cleanup "$cpids"`
		cpids=${cpids%E}
		kseq=${kseq#*/}
	done
	if [[ "$cpids" ]]; then
		info_out "Children aren't terminated - sending SIGKILL to children..."
		childs_sendsig "$cpids" KILL
		cnt=""
		while [[ "$cpids" ]] && [[ $cnt != "..." ]]; do
			cnt="${cnt}."
			sleep 2s
			cpids=`cpids_cleanup "$cpids"`
			cpids=${cpids%E}
		done
	fi

	if [[ "$cpids" ]]; then
		err_exit "Child isn't terminated after SIGKILL - may be it waiting IO"
	fi
}

childs_sendsig()
{
	local sig cpids cpid tag

	cpids="$1"
	sig=$2
	while [[ "$cpids" ]]; do
		cpid=${cpids%%$NL*}
		cpids="${cpids#*$NL}"

		tag=${cpid%% *}
		cpid=${cpid#* }
		info_out "Sending SIG$sig to a child $tag..."
		kill -$sig $cpid
	done
}

rm_old_logs()
{
	local fname fnames p IFS_old cnt

	fnames=""
	while read fname; do
		# If the file name doesn't match the prefix, then skip it.
		p="${fname#$1}"
		if [[ "$p" = "$fname" ]]; then
			continue
		fi
		fnames="$fname$NL$fnames"
	done < <(ls -1 "$SV_LOGPATH/")

	IFS_old="$IFS"
	IFS="$NL"
	cnt=$2
	for fname in $fnames; do
		if [[ $cnt -gt 0 ]]; then
			cnt=$((cnt - 1))
			continue
		fi
		rm -f $fname
	done
	IFS="$IFS_old"
}

reopen_childs_logs()
{
	local cpids cpid tag

	if [[ "$SV_SYSLOG" ]] || [[ -z "$SV_LOGPATH" ]]; then
		return
	fi

	SVLOG_POSTFIX=`mk_svlog_postfix`
	LOG_POSTFIX=`mk_log_postfix`
	exec >>"$SV_LOGPATH/${SVTAG}-sv.log-$SVLOG_POSTFIX" 2>>"$SV_LOGPATH/${SVTAG}-sv.err.log-$SVLOG_POSTFIX"
	rm_old_logs "${SVTAG}-sv.log" $SV_LOGFILES_CNT
	rm_old_logs "${SVTAG}-sv.err.log" $SV_LOGFILES_CNT

	cpids="$CPIDS"
	while [[ "$cpids" ]]; do
		cpid=${cpids%%$NL*}
		cpids="${cpids#*$NL}"

		tag=${cpid%% *}
		cpid=${cpid#* }

		if is_child_log_is_big $tag; then
			info_out "Stop child $tag for log reopening..."
			childs_kill "$tag $cpid$NL"
		fi
		rm_old_logs "$SVTAG.$tag.log" $SV_PRG_LOGFILES_CNT
		rm_old_logs "$SVTAG.$tag.err.log" $SV_PRG_LOGFILES_CNT
	done

	childs_cleanup
}

is_child_log_is_big()
{
	local fname p last_log log_size log_prefix

	for log_prefix in "$SVTAG.$1.log" "$SVTAG.$1.err.log"; do
		last_log=
		while read fname; do
			# If the file name doesn't match the prefix, then skip it.
			p="${fname#$log_prefix}"
			if [[ "$p" = "$fname" ]]; then
				continue
			fi
			last_log="$fname"
		done < <(ls -1 "$SV_LOGPATH/")
		if [[ "$last_log" ]]; then
			log_size=`stat -c%s "$SV_LOGPATH/$last_log"`
			if [[ "$log_size" -gt "$SV_PRG_LOGFILE_MAXSIZE" ]]; then
				return 0
			fi
		fi
	done

	return 1
}

mk_svlog_postfix()
{
	echo `date +'%Y%m%d'`
}

mk_log_postfix()
{
	echo `date +'%Y%m%dT%H%M%S'`
}

show_usage()
{
	echo "Usage: `basename $0` -h|--help"
	echo "       `basename $0` -v|--version"
	echo "       `basename $0` TAG"
	echo "  Where:"
	echo "    TAG           - prefix for supervisor log and pid files (no '-' at start)"
}

show_version()
{
	echo "Version 2.1"
}

case "${1:-}" in
-h|--help|help)
	show_usage
	exit
	;;
-v|--version)
	show_version
	exit
	;;
-SUPERVISE)
	SVTAG=$2
	;;
-*)
	err_exit "Wrong option: $1"
	exit 1
	;;
*)
	save_cmds
	if [[ "$SV_PIDPATH" ]]; then
		SV_PIDPATH=`mk_abspath "$SV_PIDPATH"`
	fi
	if [[ "$SV_LOGPATH" ]]; then
		SV_LOGPATH=`mk_abspath "$SV_LOGPATH"`
	fi
	setsid $0 -SUPERVISE $1 &
	exit
	;;
esac

if [[ "$SV_PIDPATH" ]] && [[ ! -e "$SV_PIDPATH" ]]; then
	mkdir -p "$SV_PIDPATH" ||
	  err_exit "Can't create pid directory"
fi
if [[ "$SV_PIDPATH" ]]; then
	echo $$ > "$SV_PIDPATH/$SVTAG.pid"
fi
SVLOG_POSTFIX=`mk_svlog_postfix`
LOG_POSTFIX=`mk_log_postfix`
if is_true "$SV_CHDIR"; then
	cd /
fi
if [[ "$SV_SYSLOG" ]]; then
	exec > >(logger -t "$SVTAG") 2>&1
else
	if [[ "$SV_LOGPATH" ]]; then
		if [[ ! -e "$SV_LOGPATH" ]]; then
			mkdir -p "$SV_LOGPATH" ||
			  err_exit "Can't create log directory"
		fi
		exec >>"$SV_LOGPATH/${SVTAG}-sv.log-$SVLOG_POSTFIX" 2>>"$SV_LOGPATH/${SVTAG}-sv.err.log-$SVLOG_POSTFIX"
	fi
fi

info_out "Starting supervisor"

trap hdl_sigterm SIGTERM
trap hdl_sigint SIGINT
trap hdl_sigquit SIGQUIT
trap hdl_sighup SIGHUP
trap _hdl_exit EXIT

RUNNING=1
RESTART=
CPIDS=""
while [[ "$RUNNING" ]]; do
	childs_start
	wait -n
	info_out "Got some signal"
	if [[ "$RUNNING" ]]; then
		# May be wait is just interruped by SIGHUP
		if childs_cleanup; then
			info_out "Wait $SV_RESTART_DELAY before restarting..."
			sleep $SV_RESTART_DELAY
		fi
	fi
	if [[ "$RESTART" ]]; then
		info_out "Got SIGHUP"
		RESTART=
		if [[ -z "$SV_SYSLOG" ]]; then
			info_out "Reopen sv log files"
			reopen_childs_logs
		fi
	fi
done

info_out "Stopping a child..."
childs_kill "$CPIDS"
info_out "Stopping supervisor"
