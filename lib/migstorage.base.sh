#!/bin/bash

# NOTE: We need 'declare -x' in order to access the variables from bash parallel

declare -xi __PID__=0
declare -xi __QUIET__=0
declare -xi __FORCE__=0
declare -xi __SYSLOG__=0
declare -xi __DEBUG_LVL__=0
declare -xi __DRY_RUN__=0
declare -x __MSG_DATE_STR__="%Y-%m-%d %H:%M:%S,%N"
declare -x __SYSLOG_QUEUE__=""


execute_set_output() {
    ###
    # Execute force command storing stdout in $1 and stderr in $2
    # NOTE: Pass $1 and $2 directly without local variable creation
    #       as name clash will hinder values to reach caller
    ###
    __execute_set_output "execute" "${1}" "${2}" "${*:3}"
    ret=$?

    return $ret

}; declare -xf execute_set_output


execute_force_set_output() {
    ###
    # Execute force command storing stdout in $1 and stderr in $2
    # NOTE: Pass $1 and $2 directly without local variable creation
    #       as name clash will hinder values to reach caller
    ###
    __execute_set_output "execute_force" "${1}" "${2}" "${*:3}"
    ret=$?

    return $ret

}; declare -xf execute_force_set_output


__execute_set_output() {
    ###
    # execute command storing stdout in $1 and stderr in $2
    # NOTE: Pass $2 (stdout result variable) and $3 (stderror result variable) 
    #       directly without local variable creation
    #       as name clash will hinder values to reach caller
    ###
    # 
    #   https://stackoverflow.com/questions/11027679/capture-stdout-and-stderr-into-different-variables
    #   1) some_command is launched: we then have some_command's stdout on the descriptor 1, 
    #      some_command's stderr on the descriptor 2 and some_command's exit code redirected to the descriptor 3
    #   2) stdout is piped to tr (sanitization)
    #   3) stderr is swapped with stdout (using temporarily the descriptor 4) and piped to tr (sanitization)
    #   4) the exit code (descriptor 3) is swapped with stderr (now descriptor 1) and piped to exit $(cat)
    #   5) stderr (now descriptor 3) is redirected to the descriptor 1, end expanded as the second argument of printf
    #   6) the exit code of exit $(cat) is captured by the third argument of printf
    #   7) the output of printf is redirected to the descriptor 2, where stdout was already present
    #   8) the concatenation of stdout and the output of printf is piped to read
    ###
    declare -r executer="${1}"
    declare -r _cmd_="${*:4}"
    {
        declare -i _ERRNO_=0
        IFS=$'\n' read -r -d '' "${2}";
        IFS=$'\n' read -r -d '' "${3}";
        (IFS=$'\n' read -r -d '' _ERRNO_; return "${_ERRNO_}");
    } < <((printf '\0%s\0%d\0' \
            "$( ( ( ({ "${executer}" "$_cmd_"; echo "${?}" 1>&3-; } \
            | tr -d '\0' 1>&4-) 4>&2- 2>&1- \
            | tr -d '\0' 1>&4-) 3>&1- \
        | exit "$(cat)") 4>&1-)" "${?}" 1>&2) 2>&1)
}; declare -xf __execute_set_output;


execute() {
    declare -i ret=0
    __execute "${__DRY_RUN__}" "${*}"
    ret=$?

    return $ret
}; declare -xf execute


execute_force() {
    declare -i ret=0
    __execute "0" "${*}"
    ret=$?

    return $ret
}; declare -xf execute_force


__execute() {
    declare -r _dry_run_="${1}"
    declare -r _cmd_="${*:2}"
    declare -i ret=0
    
    if [[ -n "$_dry_run_" && $_dry_run_ -eq 1 ]]; then
        info "dry-run: $_cmd_"
    else
        debug 3 "$_cmd_"
        eval "$_cmd_"
        ret=$?        

        # debug 3 "$_cmd_ : $ret"
        # iferror $ret "Failed with exit code $ret : $_cmd_"
    fi
    return $ret
}; declare -xf __execute


info() {
    declare -r _msg_="${*}"
    declare -r msg="INFO: $_msg_"
    [ $__QUIET__ -eq 0 ] && echo -e "\e[32m$(date "+${__MSG_DATE_STR__}") $msg\033[0m" >&2
    [ $__SYSLOG__ -eq 1 ] \
        && logger -p "${__SYSLOG_QUEUE__}.info" -t "migmount[$__PID__]" "$msg"
    return 0
}; declare -xf info


error() {
    declare -r _msg_="${*}"
    declare -r msg="ERROR: $_msg_"
    [ $__QUIET__ -eq 0 ] && echo -e "\e[31m$(date "+${__MSG_DATE_STR__}") $msg\033[0m" >&2
    [ $__SYSLOG__ -eq 1 ] \
        && logger -p "${__SYSLOG_QUEUE__}.error" -t "migmount[$__PID__]" "$msg"
    return 0
}; declare -xf error


warning() {
    declare -r _msg_="${*}"
    declare -r msg="WARNING: $_msg_"
    [ $__QUIET__ -eq 0 ] && echo -e "\e[91m$(date "+${__MSG_DATE_STR__}") $msg\033[0m" >&2
    [ $__SYSLOG__ -eq 1 ] \
        && logger -p "${__SYSLOG_QUEUE__}.warn" -t "migmount[$__PID__]" "$msg"
    return 0
}; declare -xf warning


debug() {
    declare -ri _level_="${1}"
    declare -r _msg_="${*:2}"
    declare -r msg="DEBUG$_level_: $_msg_"
    [ "$__QUIET__" -eq 0 ] && [ "$__DEBUG_LVL__" -ge "$_level_" ] \
        && echo -e "\e[34m$(date "+${__MSG_DATE_STR__}") $msg\\033[0m " >&2 
    [ "$__DEBUG_LVL__" -ge "$_level_" ] \
        && [ $__SYSLOG__ -eq 1 ] \
        && logger -p "${__SYSLOG_QUEUE__}.debug" -t "migmount[$__PID__]" "$msg"
    return 0
}; declare -xf debug


echo_stderr() {
    ###
    # echo to stderror if provided debug level is less than 
    # execution debug level
    ###
    declare -i _level_="${1}"
    declare -r _msg_="${*}"
    [ "$__QUIET__" -eq 0 ] && [ "$__DEBUG_LVL__" -lt "$_level_" ] \
        && echo "$_msg_" >&2 
}; declare -xf echo_stderr


echo_stderr_debug() {
    ###
    # echo to stderror if provided debug level is greater than 
    # or equal to execution debug level
    ###
    declare -i _level_="${1}"
    declare -r _msg_="${*:2}"

    [ "$__QUIET__" -eq 0 ] && [ "$__DEBUG_LVL__" -ge "$_level_" ] \
        && echo "$_msg_" >&2 
}; declare -xf echo_stderr_debug


develop () {
    declare -r _msg_="${*}"
    _msg_="DEVELOP: $_msg_"
    echo -e "\e[37m\e[100m$(date "+${__MSG_DATE_STR__}") $_msg_\e[49m\033[0m " >&2
    [ $__SYSLOG__ -eq 1 ] \
        && logger -p "${__SYSLOG_QUEUE__}.debug" -t "migmount[$__PID__]" "$_msg_"
    return 0
}; declare -xf develop


ifok() {
    declare -i _checkcode_="${1}"
    declare -r _msg_="${*:2}"

    [ "$_checkcode_" -eq 0 ] && info "$_msg_"
    return 0
}; declare -xf ifok


iferror() {
    declare -i _checkcode_="${1}"
    declare -r _msg_="${*:2}"
    [ "$_checkcode_" -gt 0 ] && error "$_msg_"
    return 0
}; declare -xf iferror


iferrorexit() {
    declare -i _checkcode_="${1}"
    declare -r _msg_="${*:2}"
    iferror "$_checkcode_" "$_msg_"
    [ "$__FORCE__" -eq 0 ] && [ "$_checkcode_" -gt 0 ] && exit "$_checkcode_"
    return 0
}; declare -xf iferrorexit
