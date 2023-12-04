#!/bin/bash

export SV_PRG_LOGFILE_MAXSIZE=1
export SV_LOGPATH=tmp
export SV_PIDPATH=tmp
export SV_HOOK=./hook.sh

rm tmp/*
echo "run prg1 one ./prg.sh" | ./sv.sh env1
