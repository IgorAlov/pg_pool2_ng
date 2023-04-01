#!/bin/bash

BIN_RM=/usr/bin/rm
BIN_IP=/usr/sbin/ip
BIN_ECHO=/usr/bin/echo
BIN_GREP=/usr/bin/grep
BIN_HEAD=/usr/bin/head
BIN_TEST=/usr/bin/test
BIN_LOGGER=/usr/bin/logger

CFG_ID=0
CFG_IF=lo
CFG_IP=198.18.2.0/32
CFG_PS=/var/log/postgresql/pgpool_status

MSG=""

if [ $# -ne 2 ]; then
    ${BIN_ECHO} "USAGE ${0} (action) (num)"
    exit 0
fi

if [ "${2}" == "${CFG_ID}" ]; then
    case "${1}" in
        add)
            if [ ! -r ${CFG_PS} ] || [ "up" == `${BIN_HEAD} -n1 ${CFG_PS}` ]; then
                MSG="Addr ${CFG_IP} adding"
                ${BIN_IP} -br address show dev ${CFG_IF} | ${BIN_GREP} -qc1 ${CFG_IP} || ${BIN_IP} address add ${CFG_IP} dev ${CFG_IF}
            else
                MSG="Skip adding address"
            fi
            ;;
        del)
            MSG="Addr ${CFG_IP} removing"
            ${BIN_IP} -br address show dev ${CFG_IF} | ${BIN_GREP} -qc1 ${CFG_IP} && ${BIN_IP} address del ${CFG_IP} dev ${CFG_IF}
            ;;
        clean)
            MSG="Clean file ${CFG_PS}"
            ${BIN_TEST} -w ${CFG_PS} && ${BIN_TEST} "up" != `${BIN_HEAD} -n1 ${CFG_PS}` && ${BIN_RM} ${CFG_PS}
            ;;
        *)
            MSG="wrong action"
            ${BIN_ECHO} "action could be add or del"
            ;;
    esac
fi

${BIN_LOGGER} "pgpool2:${0}, ACT: ${1}, ID: ${2}, MSG: ${MSG}"

exit 0
