#!/bin/bash
export PATH=${PATH}:/usr/local/sbin
export LD_LIBRARY_PATH="/usr/local/lib64":${LD_LIBRARY_PATH}

# Define global script variables

declare __scriptname__=${0##*/}
declare __scriptpath__=${0%/*}
declare __action__=""

# Define global variables shared with migstorage.base

declare -x __FORCE__=0
declare -x __QUIET__=0
declare -x __DRY_RUN__=0
declare -x __DEBUG_LVL__=0
declare -x __SYSLOG__=0

# Import site conf

declare -a __siteconfs__=("$__scriptpath__/../etc/migmount.conf")
for conf in "${__siteconfs__[@]}"; do
    if [ -f "${conf}" ]; then
        source "${conf}"
    else
        logger -t "migmount[$$]" "Failed to load conf file: '${conf}'"
        exit 1
    fi
done


# Import shared libraries

declare -a __sharedlibs__=("$__scriptpath__/../lib/migstorage.bash.env.sh" \
                           "$__scriptpath__/../lib/migstorage.base.sh" \
                           "$__scriptpath__/../lib/migstorage.mount.sh")

for lib in "${__sharedlibs__[@]}"; do
    if [ -f "${lib}" ]; then
        source "${lib}"
    else
        logger -t "migmount[$$]" "Failed to load shared lib: '${lib}'"
        exit 1
    fi
done


# Set global variables defined and used in migstorage.bash

__PID__=$$
__SYSLOG__=1


usage() {
    # Usage help for mount
    echo "Usage: $__scriptname__ [OPTIONS] action"
    echo "Where action is one of the following:"
    echo "  local"
    echo "  gluster"
    echo "  lustre"
    echo "  lustre-gocryptfs"
    echo "  migrate"
    echo "Where OPTIONS include:"
    echo "-h        display this help"
    echo "-q        quiet"
    echo "-v        debug mode"
    echo "-t        talkative mode"
    echo "-d        debug mode"
    echo "-f        force"
    echo "-y        dry run"
}


parse_input() {
    # Parse command line options and arguments
    declare -i OPTIND

    # Parse commandline options
    
    while getopts hfqvtdy opt; do
        case "$opt" in
            h)      usage
                    exit 0;;
            f)      __FORCE__=1;;
            q)      __QUIET__=1;;
            v)      __DEBUG_LVL__=1;;
            t)      __DEBUG_LVL__=2;;
            d)      __DEBUG_LVL__=3;;
            y)      __DRY_RUN__=1;;
            \?)     # unknown flag
                    usage
                    exit 1;;
        esac
    done
    
    # Drop options

    shift $((OPTIND-1))

    # Parse args

    __action__="${*}"

    if [ -z "$__action__" ]; then
        error "Missing action"
        usage
        exit 1
    fi    
}


main() {
    # Main
    declare cmd=""
    parse_input "${@}"
    info "$__scriptname__ $__action__"
    cmd="pre_umount_stop_services"
    execute_force "$cmd"
    ret=$?
    iferror $ret "Failed to stop services: ${PRE_UMOUNT_SERVICES}"
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    if [ "$__action__" == "local" ]; then
        cmd="umount_local"
        execute_force "$cmd"
        ret=$?
    elif [ "$__action__" == "gluster" ]; then
        cmd="umount_gluster"
        execute_force "$cmd"
        ret=$?
    elif [ "$__action__" == "lustre" ]; then
        cmd="umount_lustre"
        execute_force "$cmd"
        ret=$?
    elif [ "$__action__" == "lustre-gocryptfs" ]; then
        cmd="umount_lustre_gocryptfs"
        execute_force "$cmd"
        ret=$?
    elif [ "$__action__" == "migrate" ]; then
        cmd="umount_migrate_with_gluster_base"
        execute_force "$cmd"
        ret=$?
    else
        error "Unsupported action $__action__"
        usage
        exit 
    fi
    iferror $ret "$__scriptname__ $__action__ failed"
    ifok $ret "$__scriptname__ $__action__ succeeded"
    return $ret
}

# === Main ===


if [ "$(id -u)" != "0" ]; then
    error "Must be run as root"
    exit 1
fi

main "${@}"
exit $?
