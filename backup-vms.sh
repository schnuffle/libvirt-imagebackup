#!/bin/bash

# Online backup for KVM guests

# Copyright 2016, 2017,
#     Jens Tautenhahn <shogun@tausys.de>
#     Christian Roessner <c@roessner.co>
#
# Contributors: Jan Wenzel, Oliver Guenther, Stephan Eisvogel

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License at <http://www.gnu.org/licenses/> for
# more details.
#

CONFIG=/etc/backup-vms.conf

# ============================================================================

if [ ! -n "$BASH" ] ;then echo Please run this script with bash; exit 1; fi

#
# Exit on config check
#
function exit_on_check() {
    echo >&2 "$*"
    exit 1
}

#
# Config sanity checks
#

[[ -f $CONFIG ]] || exit_on_check "Config file $CONFIG not found."
source $CONFIG

command -v virsh >/dev/null 2>&1 || exit_on_check "Libvirt not found.  Aborting."
command -v rsync >/dev/null 2>&1 || exit_on_check "Rsync not found.  Aborting."
command -v $ZIP_BIN >/dev/null 2>&1 || exit_on_check "7Zip not found.  Aborting."
command -v fuser >/dev/null 2>&1 || exit_on_check "fuser not found.  Aborting."


for var in DST; do
    [[ -n ${!var} ]] || exit_on_check "${var} is not set"
done
if [[ -n $DSTEXT ]]; then
    [[ -n $PASSPHRASE ]] || exit_on_check "PASSPHRASE is not set"
    [[ -f $PASSPHRASE ]] || exit_on_check "PASSPHRASE file not found"
fi
for var in OFFLINE BACKUPDIRS TASKS; do
    [[ "$(declare -p $var 2> /dev/null)" =~ "declare -a" ]] || exit_on_check "$var must be an array"
done
for dir in ${BACKUPDIRS[@]}; do
    [[ -d $dir ]] || exit_on_check "BACKUPDIRS $dir not found"
done

# If no passphrase is set, we still want to be able to backup local files
ZIPPASS=
[[ -n ${PASSPHRASE} ]] && ZIPPASS="-p${PASSPHRASE}"

# Set optional Logfileparameter
LOGPARM=tee
[[ -n ${LOG} ]] && LOGPARM="tee -a $LOG"

DATE=$(date +%Y%m%d)
TIMESTAMP=$(date +%s)
LOCK=/var/lock/${0##*/}

# if ONE_FOLDER_PER_BACKUP is set to true, a new folder (based on the current timestamp) will be created for every backup.
if [ "$ONE_FOLDER_PER_BACKUP" = true ] ; then
    DST=$DST/$TIMESTAMP
fi


if ! mkdir $LOCK 2>/dev/null; then
    echo Already running or stale lock ${LOCK} exists. >&2
    exit 1
fi
trap -- "rmdir $LOCK" EXIT

[[ -d ${DST} ]] || mkdir -p ${DST}

rm -f ${DST}/LATEST_*
if [[ -n "$DSTEXT" ]]; then
    rm -f ${DSTEXT}/LATEST_*
fi

# Load last Runtime
RUNTIME=0
if [ -f ${DST}/STATUS ]; then
    source ${DST}/STATUS
fi
STARTED=`date +%s`

#
# Logline
#
function logline() {
    echo $(date -R) "$*" | $LOGPARM
}

function status_ok() {
    echo STATUS=OK > ${DST}/STATUS
    echo STARTED=$STARTED >> ${DST}/STATUS
    echo RUNTIME=$((`date +%s` - $STARTED)) >> ${DST}/STATUS
}

function status_running() {
    echo STATUS=RUNNING > ${DST}/STATUS
    echo STARTED=$STARTED >> ${DST}/STATUS
    echo RUNTIME=$RUNTIME >> ${DST}/STATUS
}

function status_failed() {
    echo STATUS=FAILED > ${DST}/STATUS
    echo STARTED=$STARTED >> ${DST}/STATUS
    echo RUNTIME=$RUNTIME >> ${DST}/STATUS
}

#
# Verify returncodes of a pipe on exit, if at least one is none zero
#

function exit_on_error() {
	rcs=${PIPESTATUS[*]}; rc=0; for i in ${rcs}; do rc=$(($i > $rc ? $i : $rc)); done
	if (( $rc != 0 )); then
		logline "Error: Process $* exited with code $rc"
		status_failed
		exit $rc
	fi
}

#
# Backup running guests
#
function run_online() {
    for vm in $(virsh list --name); do
        for exc in ${OFFLINE[@]}; do
            if [[ "${vm}" == "${exc}" ]]; then
                continue 2
            fi
        done
        for excl in ${SKIP[@]}; do
            if [[ "${vm}" == "${excl}" ]]; then
                logline "Skipping ${vm}"
                continue 2
            fi
        done

        unset imgs
        unset imgsnew

        logline "Backup KVM online guest '${vm}'"

        # Get list of disk names and image paths
        declare -A imgs
        eval $(virsh domblklist ${vm} --details \
                | awk '/^[[:space:]]*file[[:space:]]+disk/ {print "imgs["$3"]="$4}')

        # Test if there exists already a file with extension .backup
        for img in ${imgs[@]}; do
            # Skip suffix as it will already be created with basename + backup
            img=${img%@(.img|.qcow2)}
            if [[ -f ${img}.backup ]]; then
                logline "${img}.backup from VM ${vm} already exists"
                continue 2
            fi
        done

        # Create snapshots for all disks
        virsh snapshot-create-as ${vm} backup \
            --disk-only --atomic --no-metadata --quiesce 2>&1 | $LOGPARM
        exit_on_error virsh snapshot-create

        # Remember backup file names for future removal
        declare -A imgsbackup
        eval $(virsh domblklist ${vm} --details \
            | awk '/^file +disk/ {print "imgsbackup["$3"]="$4}')

        # Backup original disk image of the VM
        for img in ${imgs[@]}; do
            mkdir -p ${DST}/${vm}/
            touch ${DST}/${vm}
            if [[ -f ${DST}/${vm}/$(basename ${img}) ]]; then
                if [ -n ${HISTORY} ]; then
                    if [[ -f ${DST}/${vm}/$(basename ${img}).1 ]]; then
                        rm ${DST}/${vm}/$(basename ${img}).1
                        exit_on_error remove old backup
                    fi
                    mv ${DST}/${vm}/$(basename ${img}) ${DST}/${vm}/$(basename ${img}).1
                    exit_on_error move old backup
                else
       	            rm ${DST}/${vm}/$(basename ${img})
                fi
            fi
            rsync --progress --sparse ${img} ${DST}/${vm}/ 2>&1 | $LOGPARM
            exit_on_error rsync
        done

        # Merge snapshot file with original disk image
        for disc in ${!imgs[@]}; do
            virsh blockcommit ${vm} ${disc} --active --wait --pivot 2>&1 | $LOGPARM
            exit_on_error virsh blockcommit
        done

        # Test if all original disks are back in place
        declare -A imgsnew
        eval $(virsh domblklist ${vm} --details | \
            awk '/^file +disk/ {print "imgsnew["$3"]="$4}')
        for disc in ${!imgsnew[@]}; do
            if [[ ${imgs[$disc]} != ${imgsnew[$disc]} ]]; then
                logline "Error while writing snapshot for VM ${vm} ${disc}"
                continue 2
            fi
        done

        # Sanity check/cleanup that no original filename is in the backup array
        for match in "${imgs[@]}"; do
            for i in "${!imgsbackup[@]}"; do
                if [[ ${imgsbackup[$i]} = "${match}" ]]; then
                    unset "imgsbackup[$i]"
                fi
            done
        done

        # Remove orphaned backup snapshot files
        for img in ${imgsbackup[@]}; do
            fuser -s ${img} || rm ${img}
            exit_on_error remove orphaned backup snapshots
        done
        unset imgsbackup

        # Save XML VM definition file
        virsh dumpxml ${vm} > ${DST}/${vm}/domain.xml
        logline "Backup KVM of '${vm}' complete"
    done
}

#
# Shutdown guests that need to be ofline for a backup
#
function shutdown_offline() {
    declare -i count

    for exc in ${OFFLINE[@]}; do
        for excl in ${SKIP[@]}; do
            if [[ "${exc}" == "${excl}" ]]; then
                continue 2
            fi
        done
        logline "Shutting down '${exc}'"
        virsh shutdown ${exc}
        count=0
        while true; do
            # fix problem with prefixes in vm-names (e.g. vms1 vs vms12)
            virsh list | grep "${exc} " >/dev/null 2>&1
            if [[ "$?" -eq 1 ]]; then
                break
            fi
            sleep 5

            let count=${count}+1

            if [[ ${count} -gt 300 ]]; then
                logline "Failed to shutdown guest ${exc}"
                for force in ${FORCE_SHUTDOWN[@]}; do
                    if [[ "${force}" == "${exc}" ]]; then
                        logline "Attempt to destroy ${exc}"
                        virsh destroy ${exc}
                        # wait an extra minute
                        count=288
                        continue 2
                    fi
                done
                exit 1
            fi
        done
    done
}


#
# Backup inactive VMs
#
function run_offline() {
    shutdown_offline

    for vm in $(virsh list --name --inactive); do
        for excl in ${SKIP[@]}; do
            if [[ "${vm}" == "${excl}" ]]; then
                logline "Skipping ${vm}"
                continue 2
            fi
        done
    
        unset imgs
        logline "Backup KVM offline guest '${vm}'"

        # Get list of image names and paths
        declare -A imgs
        eval $(virsh domblklist ${vm} --details \
               | awk '/^file +disk/ {print "imgs["$3"]="$4}')

        # Backup original disk image of the VM
        for img in ${imgs[@]}; do
            mkdir -p ${DST}/${vm}/
            touch ${DST}/${vm}
            if [[ -f ${DST}/${vm}/$(basename ${img}) ]]; then
                rm ${DST}/${vm}/$(basename ${img})
            fi
            rsync --progress --sparse ${img} ${DST}/${vm}/ | $LOGPARM
	    exit_on_error rsync
        done
        # Save XML VM definition file
        virsh dumpxml ${vm} > ${DST}/${vm}/domain.xml

        for exc in ${OFFLINE[@]}; do
            if [[ "${vm}" == "${exc}" ]]; then
                virsh start ${exc} | $LOGPARM
            fi
        done
    done
}

#
# Encrypt disk image files and copy them to the NFS volume
#
function encrypt() {
    # Enrypt and copy to $DSTEXT
    for vm in $(virsh list --name --all); do
        logline "Compress and encrypt data '${vm}'"

        (
            cd ${DST}
            [[ -f ${vm}.tar.7z ]] && rm -f ${vm}.tar.7z
            tar cf - --sparse ${vm} | \
                $ZIP_BIN a -si -m0=lzma2 -mx=3 -bso0 -bsp0 -p$(< ${PASSPHRASE}) \
                    ${vm}.tar.7z | $LOGPARM
        )
        if [ -n $DSTEXT ]; then
            logline "Copy 7z file to $DSTEXT"
            cp -f ${DST}/${vm}.tar.7z ${DSTEXT}/
        fi
    done
}

#
# Backup some local directories and copy them to $DSTEXT
#
function backup_local_dirs() {
    for dir in ${BACKUPDIRS[@]}; do
        logline "Backup '${dir}'"
        dirname=$(basename ${dir})

        [[ -f ${DST}/${dirname}.tar.7z ]] && rm -f ${DST}/${dirname}.tar.7z

        tar cpf - ${dir} 2>/dev/null | \
            $ZIP_BIN a -si -m0=lzma2 -mx=3 $ZIPPASS \
                ${DST}/${dirname}.tar.7z 2>&1 | $LOGPARM

        if [ -n "$DSTEXT" ]; then
            logline "Copy 7z file to $DSTEXT"
            cp -f ${DST}/${dirname}.tar.7z ${DSTEXT}/ | $LOGPARM
        fi
    done
}

logline "Backup started"
status_running
for task in ${TASKS[@]}; do
    eval "${task}"
done

touch ${DST}/LATEST_${DATE}
if [[ -n "$DSTEXT" ]]; then
    touch ${DSTEXT}/LATEST_${DATE}
fi
status_ok
logline "Backup done"
logline "-----------"

exit 0
# vim: set ai ts=4 sw=4 et sts=4 ft=sh:
