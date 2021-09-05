#!/bin/bash

LOG_FILE=~/logs/memory.log

savelog -n -c 60 ${LOG_FILE}

date >> ${LOG_FILE}
ps -eo pid,cmd,%cpu,%mem --sort=-%mem  | head -10 >> ${LOG_FILE}
