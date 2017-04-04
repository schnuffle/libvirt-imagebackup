#!/bin/bash

# Online backup for KVM guests

# Copyright 2016,
#     Jens Tautenhahn <shogun@tausys.de>
#     Christian Roessner <c@roessner.co>
#
# Contributors: Jan Wenzel

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

if [[ ! -f $CONFIG ]]; then
    echo Config file $CONFIG not found.
    exit 1
fi
source $CONFIG

#
# Config sanity checks
#
for var in DIR XML DST; do
    [ -z "${!var}" ] && echo "${var} is not set" && exit 1
done
if [ -n "$DSTEXT" ]; then
    [ -z "$PASSPHRASE" ] && echo "PASSPHRASE is not set" && exit 1
    [ ! -f "${PASSPHRASE}" ] && echo "PASSPHRASE file not found" && exit 1
    [ -z "$(which 7z)" ] && echo "7z not found" && exit 1
fi
for var in OFFLINE BACKUPDIRS TASKS; do
    if [[ ! "$(declare -p $var 2> /dev/null)" =~ "declare -a" ]]; then
        echo "$var must be an array"
        exit 1
    fi
done
for dir in ${BACKUPDIRS[@]}; do
    [ ! -d "$dir" ] && echo "BACKUPDIRS $dir not found" && exit 1
done


DATE=$(date +%Y%M%d)
LOCK=/var/lock/${0##*/}

if ! mkdir $LOCK 2>/dev/null; then
    echo Already running or stale lock ${LOCK} exists. >&2
    exit 1
fi
trap -- "rmdir $LOCK" EXIT

[[ -d ${DIR} ]] || exit 1
[[ -d ${DST} ]] || mkdir -p ${DST}

rm -f ${DST}/LATEST_*
if [[ -n "$DSTEXT" ]]; then
    rm -f ${DSTEXT}/LATEST_*
fi

#
# Helper that draws a line
#
function draw_line() {
    echo "-------------------------------------------------------------------"
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

        unset imgs
        unset imgsnew

        draw_line
        echo "Backup KVM guest '${vm}'"

        # Get list of disk names and image paths
        declare -A imgs
        eval $(virsh domblklist ${vm} --details \
                | awk '/disk/ {print "imgs["$3"]="$4}')

        # Test if there exists already a file with extension .backup
        for img in ${imgs[@]}; do
            # Skip suffix as it will already be created with basename + backup
            img=${img%@(.img|.qcow2)}
            if [[ -f ${img}.backup ]]; then
                echo "${img}.backup from VM ${vm} already exists"
                continue 2
            fi
        done

        # Create snapshots for all disks
        virsh snapshot-create-as ${vm} backup \
            --disk-only --atomic --no-metadata --quiesce
        
        # Remember backup file names for future removal
        declare -A imgsbackup
        eval $(virsh domblklist ${vm} --details \
            | awk '/disk/ {print "imgsbackup["$3"]="$4}')

        # Backup original disk image of the VM
        for img in ${imgs[@]}; do
            mkdir -p ${DST}/${vm}/
            touch ${DST}/${vm}
            if [[ -f ${DST}/${vm}/$(basename ${img}) ]]; then
                rm ${DST}/${vm}/$(basename ${img})
            fi
            rsync --sparse ${img} ${DST}/${vm}/
        done

        # Merge snapshot file with original disk image
        for disc in ${!imgs[@]}; do
            virsh blockcommit ${vm} ${disc} --active --wait --pivot
        done

        # Test if all original disks are back in place
        declare -A imgsnew
        eval $(virsh domblklist ${vm} --details | \
            awk '/disk/ {print "imgsnew["$3"]="$4}')
        for disc in ${!imgsnew[@]}; do
            if [[ ${imgs[$disc]} != ${imgsnew[$disc]} ]]; then
                echo "Error while writing snapshot for VM ${vm} ${disc}"
                continue 2
            fi
        done

        # Remove orphaned backup snapshot files
        for img in ${imgsbackup[@]}; do
            fuser -s ${img} || rm ${img}
        done
        unset imgsbackup

        # Save XML VM definition file
        virsh dumpxml ${vm} > ${DST}/${vm}/domain.xml
    done
}

#
# Shutdown guests that need to be ofline for a backup
#
function shutdown_offline() {
    draw_line
    declare -i count

    for exc in ${OFFLINE[@]}; do
        virsh shutdown ${exc}
        while true; do
            virsh list | grep "${exc}" >/dev/null 2>&1
            if [[ "$?" -eq 1 ]]; then
                break
            fi
            sleep 5

            let count=${count}+1

            if [[ ${count} -gt 300 ]]; then
                echo "Failed to shutdown guest ${exc}"

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
        unset imgs
        draw_line
        echo "Backup KVM guest '${vm}'"

        # Get list of image names and paths
        declare -A imgs
        eval $(virsh domblklist ${vm} --details \
               | awk '/disk/ {print "imgs["$3"]="$4}')
        
        # Backup original disk image of the VM
        for img in ${imgs[@]}; do
            mkdir -p ${DST}/${vm}/
            touch ${DST}/${vm}
            if [[ -f ${DST}/${vm}/$(basename ${img}) ]]; then
                rm ${DST}/${vm}/$(basename ${img})
            fi
            rsync --sparse ${img} ${DST}/${vm}/
        done
        # Save XML VM definition file
        virsh dumpxml ${vm} > ${DST}/${vm}/domain.xml

        for exc in ${OFFLINE[@]}; do
            if [[ "${vm}" == "${exc}" ]]; then
                virsh start ${exc}
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
        draw_line
        echo "Compress and encrypt data '${vm}'"

        (
            cd ${DST}
            [[ -f ${vm}.tar.7z ]] && rm -f ${vm}.tar.7z
            tar cf - --sparse ${vm} | \
                7z a -si -m0=lzma2 -mx=3 -bso0 -bsp0 -p$(< ${PASSPHRASE}) \
                    ${vm}.tar.7z
        )

        echo "Copy 7z file to $DSTEXT"
        cp -f ${DST}/${vm}.tar.7z ${DSTEXT}/
    done
}

#
# Backup some local directories and copy them to $DSTEXT
#
function backup_local_dirs() {
    for dir in ${BACKUPDIRS[@]}; do
        draw_line
        echo "Backup '${dir}'"
        dirname=$(basename ${dir})

        [[ -f ${DST}/${dirname}.tar.7z ]] && rm -f ${DST}/${dirname}.tar.7z

        tar cpf - ${dir} 2>/dev/null | \
            7z a -si -m0=lzma2 -mx=3 -bso0 -bsp0 -p$(< ${PASSPHRASE}) \
                ${DST}/${dirname}.tar.7z

        echo "Copy 7z file to $DSTEXT"
        cp -f ${DST}/${dirname}.tar.7z ${DSTEXT}/
    done
}

for task in ${TASKS[@]}; do
    eval "${task}"
done

touch ${DST}/LATEST_${DATE}
touch ${DSTEXT}/LATEST_${DATE}

echo done
exit 0

# vim: set ai ts=4 sw=4 et sts=4 ft=sh:
