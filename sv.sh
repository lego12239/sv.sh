#!/bin/bash
# Dependencies: cut, sleep, date, mkfifo, rm, sed, grep, setsid

# Default values for variables.
# Try to get them from an environment(for --DAEMONIZE).
__SV_I_AM_DAEMON__=
SV_DEBUG=$SV_DEBUG
SV_LOG_PATH="$SV_LOG_PATH"
SV_IS_FOREGROUND=$SV_IS_FOREGROUND
SV_FIFO_PATH="$SV_FIFO_PATH"
SV_CTL_FNAME="$SV_CTL_FNAME"
SV_PRG="$SV_PRG"

REQ_WAITTIME_MAX=20
WAIT_TIME_TO_STOP=10

dbg_out()
{
	if [[ -z $SV_DEBUG ]]; then
		return
	fi
	echo "DBG: $@"
}

info_out()
{
	echo "$@"
#	if [[ $? -ne 0 ]]; then
#		echo "ECHO ERR" >&3
#	fi
}

err_out()
{
	echo "$@" >&2
}

err_exit()
{
	err_out "$@"
	exit 1
}

log_open()
{
	if [[ -z $SV_IS_FOREGROUND ]]; then
		if [[ -z "$SV_LOG_PATH" ]]; then
			exec >/dev/null
			exec 2>/dev/null
			exec 5>/dev/null
			exec 6>/dev/null

			return
		fi
	fi

	rm -f "$SV_FIFO_PATH/sv-log" "$SV_FIFO_PATH/sv-errlog"
	rm -f "$SV_FIFO_PATH/sv-app-log" "$SV_FIFO_PATH/sv-app-errlog"
	mkfifo "$SV_FIFO_PATH/sv-log" || err_exit "Can't create FIFO $SV_FIFO_PATH/sv-log"
	mkfifo "$SV_FIFO_PATH/sv-errlog" || err_exit "Can't create FIFO $SV_FIFO_PATH/sv-errlog"
	mkfifo "$SV_FIFO_PATH/sv-app-log" || err_exit "Can't create FIFO $SV_FIFO_PATH/sv-app-log"
	mkfifo "$SV_FIFO_PATH/sv-app-errlog" ||
	  err_exit "Can't create FIFO $SV_FIFO_PATH/sv-app-errlog"

	log_reopen

	exec >"$SV_FIFO_PATH/sv-log"
	exec 2>"$SV_FIFO_PATH/sv-errlog"
	exec 5>"$SV_FIFO_PATH/sv-app-log"
	exec 6>"$SV_FIFO_PATH/sv-app-errlog"
}

log_reopen()
{
#	echo "Starting LOGPROC ." >&3
	log_proc "$SV_FIFO_PATH" "$SV_LOG_PATH" &
	LOGPROC_PID=$!
}

log_proc()
{
	local TS FIFO_PATH LOG_PATH CURDAY LOG_POSTFIX
	FIFO_PATH="$1"
	LOG_PATH="$2"

#	exec ${PRGPROC_IN}>&- ${PRGPROC_OUT}>&-
	# Redirect descriptors to tty or /dev/null if LOG_PATH is empty
	if [[ -z "$LOG_PATH" ]]; then
		exec >&3 2>&1 5>&1 7>&1
	fi
	exec <"$FIFO_PATH/sv-log"
	exec 3<"$FIFO_PATH/sv-errlog"
	exec 4<"$FIFO_PATH/sv-app-log"
	exec 6<"$FIFO_PATH/sv-app-errlog"

	echo "_LOGPROC_OK_" >"$FIFO_PATH/sv"
#	echo "`date +'%F %T'` INFO SV: Started LOGPROC."
	LOG_POSTFIX=
	while true; do
		TS=`date +'%F %T'`
		CURDAY=`date '+%Y%m%d'`
		if [[ $CURDAY != "$LOG_POSTFIX" ]]; then
			LOG_POSTFIX=$CURDAY
			if [[ "$LOG_PATH" ]]; then
				exec >>"$LOG_PATH/sv.log-$LOG_POSTFIX"
				exec 2>>"$LOG_PATH/sv.errlog-$LOG_POSTFIX"
				exec 5>>"$LOG_PATH/sv.app.log-$LOG_POSTFIX"
				exec 7>>"$LOG_PATH/sv.app.errlog-$LOG_POSTFIX"
			fi
		fi
		while read -t0 line; do
			read line
			echo "$TS INFO SV: $line"
		done
		while read -t0 line <&3; do
			read line <&3
			echo "$TS ERR  SV: $line" >&2
		done
		while read -t0 line <&4; do
			read line <&4
			echo "$TS INFO APP: $line" >&5
		done
		while read -t0 line <&6; do
			read line <&6
			echo "$TS ERR  APP: $line" >&7
		done
		sleep 1s
	done

	echo "$TS ERR  SV: something goes wrong"
}

run_prg()
{
	info_out "Starting PRGPROC($@)"
#	$@ <$FIFO_PATH/sv-appin >$FIFO_PATH/sv-appout 2>&6 3>&- 4>&- 5>&- 6>&- ${PRGPROC_IN}>&- ${PRGPROC_OUT}>&-
	# PRG should get default signals dispositions
#	trap - SIGTERM
#	trap - SIGINT
#	trap - SIGQUIT
#	trap - SIGHUP
	coproc { trap - SIGTERM SIGINT SIGQUIT SIGHUP; exec "$@"; } 2>&6 3>&- 4>&- 5>&- 6>&-
	PRGPROC_PID=$!
#	trap hdl_sigterm SIGTERM
#	trap hdl_sigint SIGINT
#	trap hdl_sigquit SIGQUIT
#	trap hdl_sighup SIGHUP

	exec {PRGPROC_IN}>&${COPROC[1]}- {PRGPROC_OUT}<&${COPROC[0]}-
	info_out "Started PRGPROC. PID=$PRGPROC_PID"
}

daemonize()
{
	if [[ $__SV_I_AM_DAEMON__ ]]; then
		export -n SV_LOG_PATH SV_IS_FOREGROUND SV_DEBUG SV_FIFO_PATH SV_CTL_FNAME SV_PRG
		cd /
		return
	fi
	if [[ $SV_IS_FOREGROUND ]]; then
		return
	fi

	export SV_LOG_PATH SV_IS_FOREGROUND SV_DEBUG SV_FIFO_PATH SV_CTL_FNAME SV_PRG
	setsid $0 --DAEMONIZE "$@" &
	exit
}

_hdl_sig()
{
	info_out "Got $1"
	send_req exit
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
	_hdl_sig SIGHUP
}

send_req()
{
	dbg_out "Sending '$@' cmd to PRG..."
	# Do not process new request if old one isn't finished.
	# May be this is wrong. May be exit shouldn't be an exception.
	if [[ "$request" && $1 != "exit" ]]; then
		return
	fi
	request="$@"
	req_waittime=$REQ_WAITTIME_MAX
	echo $request >&${PRGPROC_IN}
}

check_jobs()
{
	local CHILDS CHILD

	CHILDS=`jobs  -l | sed -nre 's/^[^ ]+ +([0-9]+) +Running .*$/\1/; T; p;'`
	RESTART_LOGPROC=1
	RESTART_PRGPROC=1
	for CHILD in $CHILDS; do
		case $CHILD in
		"$LOGPROC_PID")
			RESTART_LOGPROC=
			;;
		"$PRGPROC_PID")
			RESTART_PRGPROC=
			;;
		esac
	done
}

show_usage()
{
	echo "Usage: `basename $0` [OPTIONS] FIFO_PATH PROGRAM [PROGRAM ARGS]"
	echo "Supervise a PROGRAM binary."
	echo "FIFO_PATH	is a dir where fifo files for internal use will be created."
	echo "A fifo with name sv for a communication with supervisor also resides here."
	echo ""
	echo " OPTIONS:"
	echo "  -h,--help           show help"
	echo "  -l,--log-path=PATH  set path for log files"
	echo "  -f,--foreground     do not daemonize"
	echo "  -d,--debug          show debug info"
	echo "  -v,--version        show version"
}

show_version()
{
	echo "Version 0.9"
}


######################################################################
# MAIN
######################################################################

opt_exists=1
opt_name=
opt_arg=
opt_list=
while [ $opt_exists ]; do
if [ "$opt_list" ]; then
	opt_name=`printf %s "$opt_list" | cut -c1`
	opt_list=${opt_list#$opt_name}
	opt_name="-$opt_name"
	if [ -z "$opt_list" ]; then
		opt_arg=$2
		shift
	else
		opt_arg=$opt_list
	fi
else
	case $1 in
		--)
			opt_name=
			opt_arg=
			opt_exists=
			shift
			;;
		--*)
			opt_name=${1%%=*}
			if [ $opt_name = $1 ]; then
				opt_arg=$2
				shift
			else
				opt_arg=${1#*=}
			fi
			;;
		-*)
			opt_name=
			opt_arg=
			opt_list=${1#-}
			;;
		*)
			opt_name=
			opt_arg=
			opt_exists=
			;;
	esac
fi

# echo "DBG: '$opt_name', '$opt_arg', '$opt_list'"

# Do "shift; opt_list=" for every opt with arg.
# I.e., if we use opt_arg, then we must call "shift; opt_list=", to
# remove opt arg from queue of command line parameters.
case $opt_name in
	-h|--help)
		show_usage
		exit
		;;
	-v|--version)
		show_version
		exit
		;;
	-l|--log-path)
		SV_LOG_PATH="$opt_arg"
		shift; opt_list=
		;;
	-f|--foreground)
		SV_IS_FOREGROUND=1
		;;
	-d|--debug)
		SV_DEBUG=1
		;;
	--DAEMONIZE)
		__SV_I_AM_DAEMON__=1
		opt_exists=
		;;
	-*)
		echo "Wrong option: $1"
		show_usage
		exit
		;;
esac
done

if [[ -z "$__SV_I_AM_DAEMON__" ]]; then
	if [[ "$SV_LOG_PATH" ]]; then
		if ! echo "$SV_LOG_PATH" | grep '^/' >/dev/null 2>&1 ; then
			SV_LOG_PATH="$PWD/$SV_LOG_PATH"
		fi
	fi

	SV_FIFO_PATH="$1"
	if ! echo "$SV_FIFO_PATH" | grep '^/' >/dev/null 2>&1 ; then
		SV_FIFO_PATH="$PWD/$SV_FIFO_PATH"
	fi
	shift

	SV_CTL_FNAME="$SV_FIFO_PATH/sv"

	SV_PRG="$1"
	if [ -z "$SV_PRG" ]; then
		echo PROGRAM must be specified! >&2
		exit 1
	fi
	if echo "$SV_PRG" | grep '^\./\|^\.\./' >/dev/null 2>&1 ; then
		SV_PRG="$PWD/$SV_PRG"
	elif ! echo "$SV_PRG" | grep '^/' >/dev/null 2>&1 ; then
		SV_PRG_=`which "$SV_PRG"`
		if [ -z "$SV_PRG_" ]; then
			err_out "Can't find program: '$SV_PRG'"
		fi
		SV_PRG="$SV_PRG_"
	fi
	shift

	exec 3>&1

	rm -f "$SV_CTL_FNAME"
	mkfifo "$SV_CTL_FNAME" || err_exit "Can't create FIFO $SV_CTL_FNAME"
	echo _OK_ > "$SV_CTL_FNAME" &
	exec 4<"$SV_CTL_FNAME"

#	rm -f $FIFO_PATH/sv-appin $FIFO_PATH/sv-appout
#	mkfifo $FIFO_PATH/sv-appin || err_exit "Can't create FIFO $FIFO_PATH/sv-appin"
#	mkfifo $FIFO_PATH/sv-appout || err_exit "Can't create FIFO $FIFO_PATH/sv-appout"
#	echo "1" >&3
#	exec {PRGPROC_IN}>$FIFO_PATH/sv-appin
#	echo "2" >&3
#	echo "" > $FIFO_PATH/sv-appout &
#	echo "3" >&3
#	exec {PRGPROC_OUT}<$FIFO_PATH/sv-appout
#	echo "4" >&3
fi

daemonize "$@"

trap "" SIGTERM
trap "" SIGINT
trap "" SIGQUIT
trap "" SIGHUP

log_open
run_prg "$SV_PRG" "$@"

trap hdl_sigterm SIGTERM
trap hdl_sigint SIGINT
trap hdl_sigquit SIGQUIT
trap hdl_sighup SIGHUP


echo OK >&3
exec 3>&-

if [[ $SV_DEBUG ]]; then
	echo "Started"
	echo "Started" >&2
	echo "Started" >&5
	echo "Started" >&6
fi

request=
req_waittime=
running=1
# Exit when got reply from PRG to "exit" request or wait reply longer than
while [[ "$running" ]]; do
	sleep 1s
	if read -t0 line <&4; then
		read line <&4
		if [ $? = 0 ]; then
			dbg_out "CMD: $line"
			case $line in
				_OK_)
					;;
				_LOGPROC_OK_)
					info_out "Started LOGPROC. PID=$LOGPROC_PID"
					;;
				exit)
					info_out "Got exit command. Sending 'exit' to PRG..."
					send_req exit
					;;
				*)
					err_out "Unknown command: $line"
					;;
			esac
		fi
	fi
	while read -t0 line <&${PRGPROC_OUT}; do
		read line <&${PRGPROC_OUT}
		if [[ -z "$line" ]]; then
			break
		fi
		if [[ -z "$request" ]]; then
			err_out "Got reply '$line' without request"
			break
		fi
		info_out "Got reply '$line' to '$request' request"
		case $line in
		"ok ping "*)
			;;
		"ok exit")
			if [[ $request == "exit" ]]; then
				running=
			fi
			;;
		"err "*)
			err_out "PRG replied to '' with err: ${line#err }"
			;;
		*)
			err_out "PRG sent unknown reply: $line"
			;;
		esac
		if [[ "$request" != "exit" && "$request" != "SIGTERM" ]]; then
			request=
		fi
	done

	check_jobs

	if [[ $RESTART_LOGPROC ]]; then
		log_reopen
	fi
	if [[ "$RESTART_PRGPROC" ]]; then
		if [[ $request == "SIGTERM" ]]; then
			request=
		fi
		[[ $request != "exit" ]] && run_prg "$SV_PRG" "$@"
	fi

	# We need to wait some time for a reply to a sent request.
	if [[ "$request" ]]; then
		if [[ $req_waittime -le 0 ]]; then
			case $request in
			exit)
				err_out "PRG don't reply to 'exit' request. Killing it..."
				running=
				;;
			SIGTERM)
				err_out "PRG works after 'SIGTERM'. Killing it..."
				request=
				kill -KILL $PRGPROC_PID
				;;
			*)
				err_out "PRG don't reply to '$request' request. Restarting it..."
				request=SIGTERM
				kill -TERM $PRGPROC_PID
				req_waittime=11
				;;
			esac
		fi
		((req_waittime--))
	fi

done

info_out "Exiting..."
# Give a time for a last message to arrive in the log
sleep 2s

# Terminate children if they aren't exit yet.
check_jobs
if [[ -z "$RESTART_PRGPROC" ]]; then
	kill -TERM $PRGPROC_PID
fi
if [[ -z "$RESTART_LOGPROC" ]]; then
	kill -USR1 $LOGPROC_PID
fi

# Wait children to exit.
# If not, then kill they.
req_waittime=$WAIT_TIME_TO_STOP
while [[ $running ]]; do
	if [[ $req_waittime -le 0 ]]; then
		running=
	fi
	check_jobs
	if [[ "$RESTART_LOGPROC" && "$RESTART_PRGPROC" ]]; then
		exit 0
	fi
	((req_waittime--))
	sleep 1s
done

# May be this is better, then killing?
if [[ -z "$RESTART_PRGPROC" ]]; then
	if [[ "$LOG_PATH" ]]; then
		echo "`date +'%F %T'` ERR  SV: PRGPROC($PRGPROC_PID) isn't terminated" >> $LOG_PATH/sv.errlog-`date '+%Y%m%d'`
	fi
fi
if [[ -z "$RESTART_LOGPROC" ]]; then
	if [[ "$LOG_PATH" ]]; then
		echo "`date +'%F %T'` ERR  SV: LOGPROC($LOGPROC_PID) isn't terminated" >> $LOG_PATH/sv.errlog-`date '+%Y%m%d'`
	fi
fi

exit 1

# Kill children if they aren't exit yet.
check_jobs
if [[ -z "$RESTART_PRGPROC" ]]; then
	kill -KILL $PRGPROC_PID
fi
if [[ -z "$RESTART_LOGPROC" ]]; then
	kill -KILL $LOGPROC_PID
fi

exit 1
