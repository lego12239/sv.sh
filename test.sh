#!/bin/bash

export SV_LOGPATH=tmp
export SV_PIDPATH=tmp
export SV_HOOK=./hook.sh

echo "run prg1 one ./prg.sh" | ./sv.sh env1
