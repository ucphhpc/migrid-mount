#!/bin/bash

# NOTE: We need 'declare -x' in order to access the variables from bash parallel

declare -x MOUNT_BIND_OPTS="-o bind,relatime"

# Ensure MIG base ends with FQDN
declare -x MIG_LUSTRE_BASE="${LUSTRE_BACKEND_DEST}"
declare -x MIG_GLUSTER_BASE="${GLUSTER_BACKEND_DEST}"

declare -x STORAGE_BASE="/storage"
declare -x MIG_STATE_DIR="/home/mig/state"
declare -x MIG_STORAGE_BASE="${STORAGE_BASE}/${FQDN}/sitedata"

declare -x MIG_MIGRATE_DIR="migrate"
declare -x MIG_MIGRATE_ORIGIN_FINALIZE="${STORAGE_BASE}/${FQDN}/${MIG_MIGRATE_DIR}"
declare -x MIG_MIGRATE_TARGET_BASE="${STORAGE_BASE}/${MIG_MIGRATE_DIR}/destination/${FQDN}"
declare -x MIG_STATE_SYSTEM_STORAGE="${MIG_STATE_DIR}/mig_system_storage"
declare -x MIG_STATE_MIGRATE_TARGET="${MIG_STATE_SYSTEM_STORAGE}/${MIG_MIGRATE_DIR}/destination"
declare -x MIG_STATE_MIGRATE_RO_ORIGIN="${MIG_STATE_SYSTEM_STORAGE}/${MIG_MIGRATE_DIR}/origin_readonly"


__active_mountes() {
    declare -r mountpath="${1}"
    declare -i iresult=0
    declare -i ret=0
    declare cmd=""    

    cmd="mount \
        | grep \"${mountpath}\" \
        | wc -l \
        ; exit ${PIPESTATUS[0]}"
    iresult=$(execute_force "$cmd")
    ret=$?
    iferrorexit $ret "Failed to resolve active mounts for: '${mountpath}'"
    echo -n "${iresult}"

    return $ret
}


__active_lustre_mounts() {
    declare -i iresult=0
    declare cmd=""    
    cmd="__active_mountes \"${LUSTRE_BACKEND_DEST}\""
    iresult=$(execute_force "$cmd")
    iferrorexit $ret "Failed to resolve active lustre mounts: '${LUSTRE_BACKEND_DEST}'"
    echo -n "${iresult}"

    return $ret
}


__active_gluster_mounts() {
    declare -i iresult=0
    declare cmd=""    
    cmd="__active_mountes \"${GLUSTER_BACKEND_DEST}\""
    iresult=$(execute_force "$cmd")
    iferrorexit $ret "Failed to resolve active lustre mounts: '${GLUSTER_BACKEND_DEST}'"
    echo -n "${iresult}"

    return $ret
}


mount_gocryptfs() {
    declare -r srcpath="${1}"
    declare -r destpath="${2}"
    declare -r ctlsockpath="${3}"
    declare -i ret=0
    declare cmd=""
    declare result=""
    if [ -z "${srcpath}" ]; then
        error "gocryptfs mount: Misssing srcpath"
        return 1
    elif [ -z "${destpath}" ]; then
        error "gocryptfs mount: Misssing destpath"
        return 1
    # Check for data on stdin
    elif [ -z "${STDIN}" ]; then
        error "gocryptfs mount require key passed through stdin"
        return 1
    elif [ -z "${GOCRYPTFS_MOUNT_OPTS}" ]; then
        error "Misssing GOCRYPTFS_MOUNT_OPTS in migstorage.site.conf"
        return 1
    fi
    cmd="mkdir -p ${destpath}"
    execute "$cmd"
    ret=$?
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="gocryptfs ${GOCRYPTFS_MOUNT_OPTS}"
    [ -n "${ctlsockpath}" ] && cmd+=" -ctlsock \"${ctlsockpath}\""
    cmd+=" \"${srcpath}\" \"${destpath}\""
    cmd+=" 2>&1"
    # NOTE: Do NOT put STDIN in cmd as it will expose key
    result=$(execute "$cmd" <<< "$STDIN")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


mount_lustre() {
    declare -i ret=0
    declare -i activemounts=0
    declare cmd=""
    declare result=""

    # Check active mounts

    activemounts=$(__active_lustre_mounts)
    if [ "${activemounts}" -gt 0 ]; then
        error "lustre is already mounted"
        return 1
    fi

    # Mount lustre

    cmd="mount"
    [ -n "${LUSTRE_BACKEND_OPTS}" ] \
        && cmd+=" -o ${LUSTRE_BACKEND_OPTS}"
    cmd+=" -t lustre \"${LUSTRE_BACKEND_FQDN}:${LUSTRE_BACKEND_SRC}\" \"${LUSTRE_BACKEND_DEST}\""
    cmd+=" 2>&1"
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


umount_lustre() {
    declare -i ret=0
    declare cmd=""

    # Check active mounts

    cmd="__active_lustre_mounts"
    activemounts=$(execute_force "$cmd")
    if [ "${activemounts}" -eq 0 ]; then
        error "lustre is NOT mounted"
        [ "$__FORCE__" -eq 0 ] && return 1
    fi

    cmd="umount_dir \"${LUSTRE_BACKEND_DEST}\""
    execute "$cmd"
    ret=$?

    return $ret
}


mount_bind_lustre() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""
    declare result=""

    [ -z "${_destpath_}" ] && _destpath_="${MIG_STORAGE_BASE}"

    cmd="mkdir -p ${_destpath_}"
    execute "$cmd"
    ret=$?
    [ $ret -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount ${MOUNT_BIND_OPTS} \"${LUSTRE_BACKEND_DEST}/${FQDN}\" \"${_destpath_}\""
    cmd+=" 2>&1"
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


umount_bind_lustre() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""

    [ -z "$_destpath_" ] && _destpath_="${MIG_STORAGE_BASE}"

    cmd="umount_dir \"$_destpath_\""
    execute "$cmd"
    ret=$?

    return $ret
}


mount_lustre_gocryptfs() {
    declare _destpath_=""   
    [ ${#@} -gt 1 ] && _destpath_="${1}"

    declare -i ret=0
    declare cmd=""
    declare result=""
    declare srcpath="${LUSTRE_BACKEND_DEST}"
    # If lustre is not submounted into FQDN then add FQDN to srcpath
    [[ ! "${srcpath}" == *"${FQDN}" ]] && srcpath="${srcpath}/${FQDN}"
    [ -z "${_destpath_}" ] && _destpath_="${MIG_STORAGE_BASE}"

    cmd="mount_gocryptfs \"${srcpath}\" \"${_destpath_}\" \"${GOCRYPTFS_CTLSOCK}\""
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


umount_lustre_gocryptfs() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""

    [ -z "$_destpath_" ] && _destpath_="${MIG_STORAGE_BASE}"

    cmd="umount_dir \"$_destpath_\""
    execute "$cmd"
    ret=$?
    
    [ "$ret" -eq 0 ] && [ -f "${GOCRYPTFS_CTLSOCK}" ] && rm -f "${GOCRYPTFS_CTLSOCK}"
    
    return $ret
}


mount_gluster() {
    declare -i ret=0
    declare -i activemounts=0
    declare cmd=""
    declare result=""

    cmd="__active_gluster_mounts"
    activemounts=$(execute_force "$cmd")    
    if [ "${activemounts}" -gt 0 ]; then
        error "gluster already mounted"
        [ "$__FORCE__" -eq 0 ] && return 1
    fi
    cmd="mount"
    [ -n "${GLUSTER_BACKEND_OPTS}" ] \
        && cmd+=" -o ${GLUSTER_BACKEND_OPTS}"
    cmd+=" -t glusterfs \"${GLUSTER_BACKEND_FQDN}:${GLUSTER_BACKEND_SRC}\" \"${GLUSTER_BACKEND_DEST}\""
    cmd+=" 2>&1"
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


umount_gluster() {
    declare -i ret=0
    declare -i activemounts=0
    declare cmd=""

    cmd="__active_gluster_mounts"
    activemounts=$(execute_force "$cmd")
    if [ "${activemounts}" -eq 0 ]; then
        error "gluster NOT mounted"
        [ "$__FORCE__" -eq 0 ] && return 1
    fi
    cmd="umount_dir \"${GLUSTER_BACKEND_DEST}\""
    execute "$cmd"
    ret=$?

    return $ret
}


mount_bind_gluster() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""
    declare result=""

    [ -z "${_destpath_}" ] && _destpath_="${MIG_STORAGE_BASE}"

    cmd="mkdir -p ${_destpath_}"
    execute "$cmd"
    ret=$?
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount ${MOUNT_BIND_OPTS} \"${GLUSTER_BACKEND_DEST}/${FQDN}\" \"${_destpath_}\""
    cmd+=" 2>&1"
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"
        
    return $ret
}


umount_bind_gluster() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""

    [ -z "$_destpath_" ] && _destpath_="${MIG_STORAGE_BASE}"

    cmd="umount_dir \"$_destpath_\""
    execute "$cmd"
    ret=$?
    
    return $ret
}


mount_bind_migrate_dirs() {
    declare -i res=0
    declare -i ret=0
    local srcpath
    local destpath

    # Mount bind lustre 

    cmd="mount_bind_lustre \"${MIG_MIGRATE_TARGET_BASE}\""
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Mount bind gluster RO migrate dir

    cmd="mount_bind_dir \"${MIG_MIGRATE_ORIGIN_FINALIZE}\" \"${MIG_STATE_MIGRATE_RO_ORIGIN}\" 1"
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Mount bind lustre migrate dir

    cmd="mount_bind_dir \"${MIG_MIGRATE_TARGET_BASE}\" \"${MIG_STATE_MIGRATE_TARGET}\" 0"
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Mount bind lustre RO state dirs

    for key in "${!MIG_RO_STATE_DIRS[@]}"; do
        srcpath="${MIG_MIGRATE_TARGET_BASE}/$key"
        destpath="${MIG_STATE_MIGRATE_TARGET}/${MIG_RO_STATE_DIRS[$key]}"
        cmd="mount_bind_dir \"${srcpath}\" \"${destpath}\" 1"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


umount_bind_migrate_dirs() {
    declare -i res=0
    declare -i ret=0
    declare destpath=""
    declare cmd=""

    # Umount bind lustre RO state dirs

    for key in "${!MIG_RO_STATE_DIRS[@]}"; do
        destpath="${MIG_STATE_MIGRATE_TARGET}/${MIG_RO_STATE_DIRS[$key]}"
        cmd="umount_dir \"${destpath}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    # Umount bind lustre migrate dir

    cmd="umount_dir \"${MIG_STATE_MIGRATE_TARGET}\""
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    # Umount bind gluster RO migrate dir

    cmd="umount_dir \"${MIG_STATE_MIGRATE_RO_ORIGIN}\""
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Umount bind lustre 

    cmd="umount_dir \"${MIG_MIGRATE_TARGET_BASE}\""
    execute "$cmd"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount_bind_dir() {
    declare -r _srcpath_="${1}"
    declare -r _destpath_="${2}"
    declare -r _readonly_="${3}"
    declare -i ret=0
    declare cmd=""
    declare result=""

    if [ ! -d "${_srcpath_}" ]; then
        error "Missing src state dir: ${_srcpath_}"
        ret=1
        return $ret
    fi
    if [ ! -d "${_destpath_}" ]; then
        if [ -e "${_destpath_}" ]; then
            error "Dest state dir: ${_destpath_} exists but is NOT a directory"
            ret=1
            return $ret
        fi
        cmd="mkdir -p ${_destpath_}"
        execute "$cmd"
        [ $ret -ne 0 ] && return $ret
    fi
    cmd="mount ${MOUNT_BIND_OPTS}"
    [ "$_readonly_" -eq 1 ] && cmd+=",ro"
    cmd+=" ${_srcpath_} ${_destpath_}"
    cmd+=" 2>&1"
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


mount_bind_state_dirs() {
    declare -i res=0
    declare -i ret=0
    declare src=""
    declare dest=""
    declare srcpath=""
    declare destpath=""

    for key in "${!MIG_STATE_DIRS[@]}" ; do
        src="$key"
        dest="${MIG_STATE_DIRS[$key]}"
        srcpath="${MIG_STORAGE_BASE}/${src}"
        destpath="${MIG_STATE_DIR}/${dest}"
        cmd="mount_bind_dir \"${srcpath}\" \"${destpath}\" 0"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    for key in "${!MIG_RO_STATE_DIRS[@]}" ; do
        src="${key}"
        dest="${MIG_RO_STATE_DIRS[$key]}"
        srcpath="${MIG_STORAGE_BASE}/${src}"
        destpath="${MIG_STATE_DIR}/${dest}"
        cmd="mount_bind_dir \"${srcpath}\" \"${destpath}\" 1"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


umount_dir() {
    declare -r _dir_="${1}"
    declare -i res=0
    declare -i ret=0
    declare -i activemounts=0
    declare result=""

    if [ ! -d "$_dir_" ]; then
        error "Missing dest dir: $_dir_"
        ret=1
        return $ret
    fi

    cmd="__active_mountes \"${_dir_}\""
    activemounts=$(execute "$cmd")
    if [ "${activemounts}" -eq 0 ]; then
        error "${_dir_} NOT mounted"
        ret=1
        [ "$__FORCE__" -eq 0 ] && return $ret
    fi
    cmd="umount \"${_dir_}\" 2>&1"        
    result=$(execute "$cmd")
    res=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $res
}


umount_bind_state_dirs() {
    declare -i res=0
    declare -i ret=0
    declare dest=""
    declare dest_state_dir=""
    declare cmd=""

    for key in "${!MIG_RO_STATE_DIRS[@]}" ; do
        dest="${MIG_RO_STATE_DIRS[$key]}"
        dest_state_dir="${MIG_STATE_DIR}/${dest}"
        cmd="umount_dir \"${dest_state_dir}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    for key in "${!MIG_STATE_DIRS[@]}" ; do
        dest="${MIG_STATE_DIRS[$key]}"
        dest_state_dir="${MIG_STATE_DIR}/${dest}"
        cmd="umount_dir \"${dest_state_dir}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


mount_bind_storage_resources() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    
    for key in "${!MIG_STORAGE_RESOURCES[@]}" ; do
        srcdir="$key"
        destdir="${MIG_STORAGE_RESOURCES[$key]}"
        cmd="mount_bind_dir \"${srcdir}\" \"${destdir}\" 0"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done
    
    return $ret
}


umount_bind_storage_resources() {
    declare -i res=0
    declare -i ret=0
    
    for key in "${!MIG_STORAGE_RESOURCES[@]}" ; do
        destdir="${MIG_STORAGE_RESOURCES[$key]}"
        cmd="umount_dir \"${destdir}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


mount-gluster() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="mount_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_storage_resources"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount-gocryptfs-opt-dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


umount-gluster() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    
    cmd="umount_bind_storage_resources"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    cmd="umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_bind_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount-lustre() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="mount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_storage_resources"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    return $ret
}


umount-lustre() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="umount_bind_storage_resources"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_bind_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount-lustre-gocryptfs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="mount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_lustre_gocryptfs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_storage_resources"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    cmd="mount-gocryptfs-opt-dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


umount-lustre-gocryptfs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    
    cmd="umount-gocryptfs-opt-dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_bind_storage_resources"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_lustre_gocryptfs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount-migrate-with-gluster-base() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="mount_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "mount-migrate-with-gluster-base.mount_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "mount-migrate-with-gluster-base.mount_bind_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "mount-migrate-with-gluster-base.mount_bind_state_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_lustre"
    execute_force "$cmd"
    res=$?
    debug 3 "mount-migrate-with-gluster-base.mount_lustre: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="mount_bind_migrate_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "mount-migrate-with-gluster-base.mount_bind_migrate_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret    

    cmd="mount_bind_storage_resources"
    execute_force "$cmd"
    debug 3 "mount-migrate-with-gluster-base.mount_bind_storage_resources: $res"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


umount-migrate-with-gluster-base() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="umount_bind_storage_resources"
    execute_force "$cmd"
    res=$?
    debug 3 "umount-migrate-with-gluster-base.umount_bind_storage_resources: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_bind_migrate_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "umount-migrate-with-gluster-base.umount_bind_migrate_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret    

    cmd="umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "umount-migrate-with-gluster-base.umount_bind_state_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_bind_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "umount-migrate-with-gluster-base.umount_bind_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "umount-migrate-with-gluster-base.umount_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="umount_lustre"
    execute_force "$cmd"
    res=$?
    debug 3 "umount-migrate-with-gluster-base.umount_lustre: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount-gocryptfs-opt-dirs() {
    declare -i res=0
    declare -i ret=0
    declare srcpath=""
    declare destpath=""
    declare cmd=""
    for key in "${!GOCRYPTFS_OPT_DIRS[@]}"; do
        srcpath="$key"
        destpath="${GOCRYPTFS_OPT_DIRS[$key]}"
        cmd="mount_gocryptfs \"${srcpath}\" \"${destpath}\" \"\""
        result=$(execute "$cmd")
        res=$?
        debug 3 "|:|ret=$res|:|result=$result"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}

umount-gocryptfs-opt-dirs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    declare mountpath=""
    for key in "${!GOCRYPTFS_OPT_DIRS[@]}"; do
        mountpath="${GOCRYPTFS_OPT_DIRS[$key]}"
        cmd="umount_dir \"${mountpath}\""
        execute "$cmd"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}   

post_mount_start_services() {
    declare -i ret=0
    declare -i res=0
    for service in "${POST_MOUNT_SERVICES[@]}"; do
	[ -z "$service" ] && continue
        cmd="service $service start >/dev/null 2>&1"
        execute_force "$cmd"
        res=$?
        debug 3 "post_mount_start_services $res"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}

pre_umount_stop_services() {
    declare -i ret=0
    declare -i res=0
    for service in "${PRE_UMOUNT_SERVICES[@]}"; do
	[ -z "$service" ] && continue
        cmd="service $service stop >/dev/null 2>&1"
        execute_force "$cmd"
        res=$?
        debug 3 "pre_umount_start_services $res"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}
