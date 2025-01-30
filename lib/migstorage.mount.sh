#!/bin/bash

# NOTE: We need 'declare -x' in order to access the variables from bash parallel

declare -x MOUNT_BIND_OPTS="-o bind,relatime"

# Define MiG storage structure
declare -x MIG_LOCAL_BASE="${LOCAL_BACKEND_DEST}"
declare -x MIG_LUSTRE_BASE="${LUSTRE_BACKEND_DEST}"
declare -x MIG_GLUSTER_BASE="${GLUSTER_BACKEND_DEST}"
declare -x MIG_STATE_DIR="/home/mig/state"
declare -x MIG_MIGRATE_DIR="migrate"
declare -x MIG_MIGRATE_ORIGIN_FINALIZE="${STORAGE_BASE}/${FQDN}/${MIG_MIGRATE_DIR}"
declare -x MIG_MIGRATE_TARGET_BASE="${STORAGE_BASE}/${MIG_MIGRATE_DIR}/destination/${FQDN}"
declare -x MIG_STATE_SYSTEM_STORAGE="${MIG_STATE_DIR}/mig_system_storage"
declare -x MIG_STATE_MIGRATE_TARGET="${MIG_STATE_SYSTEM_STORAGE}/${MIG_MIGRATE_DIR}/destination"
declare -x MIG_STATE_MIGRATE_RO_ORIGIN="${MIG_STATE_SYSTEM_STORAGE}/${MIG_MIGRATE_DIR}/origin_readonly"


__active_mountes() {
    declare -r mountpath="${1}"
    declare -i result=0
    declare -i ret=0
    declare cmd=""

    cmd="mount \
        | grep \"${mountpath}\" \
        | wc -l \
        ; exit ${PIPESTATUS[0]}"
    result=$(execute_force "$cmd")
    ret=$?
    iferrorexit $ret "Failed to resolve active mounts for: '${mountpath}'"
    echo -n "${result}"

    return $ret
}


__active_local_mounts() {
    declare -i result=0
    declare cmd=""
    cmd="__active_mountes \"${LOCAL_BACKEND_DEST}\""
    result=$(execute_force "$cmd")
    iferrorexit $ret "Failed to resolve active local mounts: '${LOCAL_BACKEND_DEST}'"
    echo -n "${result}"

    return $ret
}


__active_lustre_mounts() {
    declare -i result=0
    declare cmd=""
    cmd="__active_mountes \"${LUSTRE_BACKEND_DEST}\""
    result=$(execute_force "$cmd")
    iferrorexit $ret "Failed to resolve active lustre mounts: '${LUSTRE_BACKEND_DEST}'"
    echo -n "${result}"

    return $ret
}


__active_gluster_mounts() {
    declare -i result=0
    declare cmd=""
    cmd="__active_mountes \"${GLUSTER_BACKEND_DEST}\""
    result=$(execute_force "$cmd")
    iferrorexit $ret "Failed to resolve active gluster mounts: '${GLUSTER_BACKEND_DEST}'"
    echo -n "${result}"

    return $ret
}


__mount_bind_dir() {
    declare -r _srcpath_="${1}"
    declare -r _destpath_="${2}"
    declare -r _readonly_="${3}"
    declare -i ret=0
    declare cmd=""
    declare result=""

    if [ ! -d "${_srcpath_}" ]; then
        error "Missing bind source dir: ${_srcpath_}"
        ret=1
        return $ret
    fi
    if [ ! -d "${_destpath_}" ]; then
        if [ -e "${_destpath_}" ]; then
            error "bind destination: ${_destpath_} exists but is NOT a directory"
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


__umount_dir() {
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


__mount_gocryptfs() {
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


__mount_local() {
    declare -i ret=0
    declare -i activemounts=0
    declare cmd=""
    declare result=""

    # Check active mounts

    # Nothing to mount if SRC equals DEST
    if [ "${LOCAL_BACKEND_SRC}" = "${LOCAL_BACKEND_DEST}" ]; then
        debug 3 "no local backend to mount"
        return 0
    fi

    activemounts=$(__active_local_mounts)
    if [ "${activemounts}" -gt 0 ]; then
        error "local is already mounted"
        return 1
    fi

    # Mount local

    cmd="mount"
    [ -n "${LOCAL_BACKEND_OPTS}" ] \
        && cmd+=" -o ${LOCAL_BACKEND_OPTS}"
    cmd+=" -t auto \"${LOCAL_BACKEND_SRC}\" \"${LOCAL_BACKEND_DEST}\""
    cmd+=" 2>&1"
    [ -n "${LOCAL_BACKEND_SRC}" ] && cmd="/bin/true"
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


__umount_local() {
    declare -i ret=0
    declare cmd=""

    # Nothing to unmount if SRC equals DEST
    if [ "${LOCAL_BACKEND_SRC}" = "${LOCAL_BACKEND_DEST}" ]; then
        debug 3 "no local backend to unmount"
        return 0
    fi

    # Check active mounts

    cmd="__active_local_mounts"
    activemounts=$(execute_force "$cmd")
    if [ "${activemounts}" -eq 0 ]; then
        error "local is NOT mounted"
        [ "$__FORCE__" -eq 0 ] && return 1
    fi

    cmd="__umount_dir \"${LOCAL_BACKEND_DEST}\""
    execute "$cmd"
    ret=$?

    return $ret
}


__mount_bind_local() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""
    declare result=""
    declare srcpath="${LOCAL_BACKEND_DEST}"
    [ -z "${_destpath_}" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="mkdir -p ${_destpath_}"
    execute "$cmd"
    ret=$?
    [ $ret -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_dir  \"${srcpath}\" \"${_destpath_}\" 0"
    execute "$cmd"
    ret=$?

    return $ret
}


__umount_bind_local() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""

    [ -z "$_destpath_" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="__umount_dir \"$_destpath_\""
    execute "$cmd"
    ret=$?

    return $ret
}


__mount_lustre() {
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


__umount_lustre() {
    declare -i ret=0
    declare cmd=""

    # Check active mounts

    cmd="__active_lustre_mounts"
    activemounts=$(execute_force "$cmd")
    if [ "${activemounts}" -eq 0 ]; then
        error "lustre is NOT mounted"
        [ "$__FORCE__" -eq 0 ] && return 1
    fi

    cmd="__umount_dir \"${LUSTRE_BACKEND_DEST}\""
    execute "$cmd"
    ret=$?

    return $ret
}


__mount_bind_lustre() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""
    declare result=""
    declare srcpath="${LUSTRE_BACKEND_DEST}"
    # If lustre is not submounted into FQDN then add FQDN to srcpath
    [[ ! "${srcpath}" == *"${FQDN}" ]] && srcpath="${srcpath}/${FQDN}"
    [ -z "${_destpath_}" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="mkdir -p ${_destpath_}"
    execute "$cmd"
    ret=$?
    [ $ret -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_dir  \"${srcpath}\" \"${_destpath_}\" 0"
    execute "$cmd"
    ret=$?

    return $ret
}


__umount_bind_lustre() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""

    [ -z "$_destpath_" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="__umount_dir \"$_destpath_\""
    execute "$cmd"
    ret=$?

    return $ret
}


__mount_lustre_gocryptfs() {
    declare _destpath_=""   
    [ ${#@} -gt 1 ] && _destpath_="${1}"

    declare -i ret=0
    declare cmd=""
    declare result=""
    declare srcpath="${LUSTRE_BACKEND_DEST}"
    # If lustre is not submounted into FQDN then add FQDN to srcpath
    [[ ! "${srcpath}" == *"${FQDN}" ]] && srcpath="${srcpath}/${FQDN}"
    [ -z "${_destpath_}" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="__mount_gocryptfs \"${srcpath}\" \"${_destpath_}\" \"${GOCRYPTFS_CTLSOCK}\""
    result=$(execute "$cmd")
    ret=$?
    debug 3 "|:|ret=$ret|:|result=$result"
    [ $ret -gt 0 ] && error "${result}"

    return $ret
}


__umount_lustre_gocryptfs() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""

    [ -z "$_destpath_" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="__umount_dir \"$_destpath_\""
    execute "$cmd"
    ret=$?
    [ "$ret" -eq 0 ] && [ -f "${GOCRYPTFS_CTLSOCK}" ] && rm -f "${GOCRYPTFS_CTLSOCK}"
    
    return $ret
}


__mount_gluster() {
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


__umount_gluster() {
    declare -i ret=0
    declare -i activemounts=0
    declare cmd=""

    cmd="__active_gluster_mounts"
    activemounts=$(execute_force "$cmd")
    if [ "${activemounts}" -eq 0 ]; then
        error "gluster NOT mounted"
        [ "$__FORCE__" -eq 0 ] && return 1
    fi
    cmd="__umount_dir \"${GLUSTER_BACKEND_DEST}\""
    execute "$cmd"
    ret=$?

    return $ret
}


__mount_bind_gluster() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""
    declare result=""
    declare srcpath="${GLUSTER_BACKEND_DEST}"
    # If gluster is not submounted into FQDN then add FQDN to srcpath
    [[ ! "${srcpath}" == *"${FQDN}" ]] && srcpath="${srcpath}/${FQDN}"
    [ -z "${_destpath_}" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="mkdir -p ${_destpath_}"
    execute "$cmd"
    ret=$?
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_dir \"${srcpath}\" \"${_destpath_}\" 0"
    execute "$cmd"
    ret=$?
        
    return $ret
}


__umount_bind_gluster() {
    declare _destpath_=""
    [ ${#@} -gt 0 ] && _destpath_="${1}"
    declare -i ret=0
    declare cmd=""

    [ -z "$_destpath_" ] && _destpath_="${MIG_DATA_BASE}"

    cmd="__umount_dir \"$_destpath_\""
    execute "$cmd"
    ret=$?
    
    return $ret
}


__mount_bind_migrate_dirs() {
    declare -i res=0
    declare -i ret=0
    local srcpath
    local destpath

    # Mount bind lustre 

    cmd="__mount_bind_lustre \"${MIG_MIGRATE_TARGET_BASE}\""
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Mount bind gluster RO migrate dir

    cmd="__mount_bind_dir \"${MIG_MIGRATE_ORIGIN_FINALIZE}\" \"${MIG_STATE_MIGRATE_RO_ORIGIN}\" 1"
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Mount bind lustre migrate dir

    cmd="__mount_bind_dir \"${MIG_MIGRATE_TARGET_BASE}\" \"${MIG_STATE_MIGRATE_TARGET}\" 0"
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Mount bind lustre RO state dirs

    for key in "${!MIG_RO_STATE_DIRS[@]}"; do
        srcpath="${MIG_MIGRATE_TARGET_BASE}/$key"
        destpath="${MIG_STATE_MIGRATE_TARGET}/${MIG_RO_STATE_DIRS[$key]}"
        cmd="__mount_bind_dir \"${srcpath}\" \"${destpath}\" 1"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__umount_bind_migrate_dirs() {
    declare -i res=0
    declare -i ret=0
    declare destpath=""
    declare cmd=""

    # Umount bind lustre RO state dirs

    for key in "${!MIG_RO_STATE_DIRS[@]}"; do
        destpath="${MIG_STATE_MIGRATE_TARGET}/${MIG_RO_STATE_DIRS[$key]}"
        cmd="__umount_dir \"${destpath}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    # Umount bind lustre migrate dir

    cmd="__umount_dir \"${MIG_STATE_MIGRATE_TARGET}\""
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    # Umount bind gluster RO migrate dir

    cmd="__umount_dir \"${MIG_STATE_MIGRATE_RO_ORIGIN}\""
    execute "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    # Umount bind lustre 

    cmd="__umount_dir \"${MIG_MIGRATE_TARGET_BASE}\""
    execute "$cmd"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


__mount_bind_state_dirs() {
    declare -i res=0
    declare -i ret=0
    declare src=""
    declare dest=""
    declare srcpath=""
    declare destpath=""

    for key in "${!MIG_STATE_DIRS[@]}" ; do
        src="$key"
        dest="${MIG_STATE_DIRS[$key]}"
        srcpath="${MIG_DATA_BASE}/${src}"
        destpath="${MIG_STATE_DIR}/${dest}"
        cmd="__mount_bind_dir \"${srcpath}\" \"${destpath}\" 0"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    for key in "${!MIG_RO_STATE_DIRS[@]}" ; do
        src="${key}"
        dest="${MIG_RO_STATE_DIRS[$key]}"
        srcpath="${MIG_DATA_BASE}/${src}"
        destpath="${MIG_STATE_DIR}/${dest}"
        cmd="__mount_bind_dir \"${srcpath}\" \"${destpath}\" 1"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__umount_bind_state_dirs() {
    declare -i res=0
    declare -i ret=0
    declare dest=""
    declare dest_state_dir=""
    declare cmd=""

    for key in "${!MIG_RO_STATE_DIRS[@]}" ; do
        dest="${MIG_RO_STATE_DIRS[$key]}"
        dest_state_dir="${MIG_STATE_DIR}/${dest}"
        cmd="__umount_dir \"${dest_state_dir}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    for key in "${!MIG_STATE_DIRS[@]}" ; do
        dest="${MIG_STATE_DIRS[$key]}"
        dest_state_dir="${MIG_STATE_DIR}/${dest}"
        cmd="__umount_dir \"${dest_state_dir}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__mount_bind_storage() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    
    for key in "${!MIG_BIND_STORAGE[@]}" ; do
        srcdir="$key"
        destdir="${MIG_BIND_STORAGE[$key]}"
        cmd="__mount_bind_dir \"${srcdir}\" \"${destdir}\" 0"
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done
    
    return $ret
}


__umount_bind_storage() {
    declare -i res=0
    declare -i ret=0
    
    for key in "${!MIG_BIND_STORAGE[@]}" ; do
        destdir="${MIG_BIND_STORAGE[$key]}"
        cmd="__umount_dir \"${destdir}\""
        execute "$cmd"
        res=$?
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__mount_gocryptfs_optional_dirs() {
    declare -i res=0
    declare -i ret=0
    declare srcpath=""
    declare destpath=""
    declare cmd=""
    for key in "${!GOCRYPTFS_OPTIONAL_DIRS[@]}"; do
        srcpath="$key"
        destpath="${GOCRYPTFS_OPTIONAL_DIRS[$key]}"
        cmd="__mount_gocryptfs \"${srcpath}\" \"${destpath}\" \"\""
        result=$(execute "$cmd")
        res=$?
        debug 3 "|:|ret=$res|:|result=$result"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__umount_gocryptfs_optional_dirs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    declare mountpath=""
    for key in "${!GOCRYPTFS_OPTIONAL_DIRS[@]}"; do
        mountpath="${GOCRYPTFS_OPTIONAL_DIRS[$key]}"
        cmd="__umount_dir \"${mountpath}\""
        execute "$cmd"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__mount_tmpfs_dirs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    declare tmpfs_mount=""
    for tmpfs_mount in "${MIG_TMPFS_DIRS[@]}"; do
        # Create tmpfs target
        [ -z "${tmpfs_mount}" ] && continue
        cmd="mkdir -p ${tmpfs_mount}"
        execute "$cmd"
        ret=$?
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
        # Mount tmpfs target
        cmd="mount -t tmpfs -o ${MIG_TMPFS_MOUNT_OPTS} tmpfs ${tmpfs_mount}"
        execute_force "$cmd"
        res=$?
        debug 3 "mount_tmpfs_dirs: $res"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__umount_tmpfs_dirs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    declare tmpfs_mount=""
    for tmpfs_mount in "${MIG_TMPFS_DIRS[@]}"; do
        [ -z "${tmpfs_mount}" ] && continue
        cmd="__umount_dir \"${tmpfs_mount}\""
        execute "$cmd"
        ret=$?
        debug 3 "umount_tmpfs_dirs: $res"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__mount_diskimg() {
    declare -i res=0
    declare -i ret=0
    declare srcpath=""
    declare destpath=""
    declare cmd=""
    for key in "${!MIG_DISKIMG_MOUNTS[@]}"; do        
        device="$key"
        destpath="${MIG_DISKIMG_MOUNTS[$key]}"
        cmd="mkdir -p ${destpath}"
        execute "$cmd"
        ret=$?
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
        # Mount tmpfs target
        cmd="mount -o \"${MIG_DISKIMG_MOUNT_OPTS}\" \"${device}\" \"${destpath}\""
        execute_force "$cmd"
        res=$?
        debug 3 "__mount_diskimg: $res"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


__umount_diskimg() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    declare mountpath=""
    for key in "${!MIG_DISKIMG_MOUNTS[@]}"; do        
        mountpath="${MIG_DISKIMG_MOUNTS[$key]}"
        cmd="__umount_dir \"${mountpath}\""
        execute "$cmd"
        [ "$res" -ne 0 ] && ret=$res
        [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    done

    return $ret
}


mount_local() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="__mount_local"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_local"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


umount_local() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="__umount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_local"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_local"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount_lustre() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="__mount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    return $ret
}


umount_lustre() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="__umount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount_lustre_gocryptfs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="__mount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_lustre_gocryptfs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    cmd="__mount_gocryptfs_optional_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


umount_lustre_gocryptfs() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    
    cmd="__umount_gocryptfs_optional_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_lustre_gocryptfs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_lustre"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount_gluster() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="__mount_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_gocryptfs_optional_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


umount_gluster() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""
    
    cmd="__umount_bind_storage"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret
    
    cmd="__umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_tmpfs_dirs"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_gluster"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


mount_migrate_with_gluster_base() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""

    cmd="__mount_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "mount_migrate_with_gluster_base.mount_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_diskimg"
    execute_force "$cmd"
    res=$?
    debug 3 "mount_migrate_with_gluster_base.__mount_diskimg: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_tmpfs_dirs"
    execute_force "$cmd"
    debug 3 "mount_migrate_with_gluster_base.mount_tmpfs_dirs: $res"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "mount_migrate_with_gluster_base.mount_bind_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "mount_migrate_with_gluster_base.mount_bind_state_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_lustre"
    execute_force "$cmd"
    res=$?
    debug 3 "mount_migrate_with_gluster_base.mount_lustre: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__mount_bind_migrate_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "mount_migrate_with_gluster_base.mount_bind_migrate_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret    

    cmd="__mount_bind_storage"
    execute_force "$cmd"
    debug 3 "mount_migrate_with_gluster_base.mount_bind_storage: $res"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    return $ret
}


umount_migrate_with_gluster_base() {
    declare -i res=0
    declare -i ret=0
    declare cmd=""


    cmd="__umount_bind_storage"
    execute_force "$cmd"
    res=$?
    debug 3 "umount_migrate_with_gluster_base.__umount_bind_storage: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_migrate_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "umount_migrate_with_gluster_base.umount_bind_migrate_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret    

    cmd="__umount_bind_state_dirs"
    execute_force "$cmd"
    res=$?
    debug 3 "umount_migrate_with_gluster_base.__umount_bind_state_dirs: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_bind_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "umount_migrate_with_gluster_base.umount_bind_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_tmpfs_dirs"
    execute_force "$cmd"
    debug 3 "umount_migrate_with_gluster_base.umount_tmpfs_dirs: $res"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_diskimg"
    execute_force "$cmd"
    res=$?
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_gluster"
    execute_force "$cmd"
    res=$?
    debug 3 "umount_migrate_with_gluster_base.umount_gluster: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

    cmd="__umount_lustre"
    execute_force "$cmd"
    res=$?
    debug 3 "umount_migrate_with_gluster_base.umount_lustre: $res"
    [ "$res" -ne 0 ] && ret=$res
    [ "$ret" -ne 0 ] && [ "$__FORCE__" -eq 0 ] && return $ret

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
