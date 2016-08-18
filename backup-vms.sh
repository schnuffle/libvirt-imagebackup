#!/bin/bash

DIR=/var/lib/libvirt/images
XML=/etc/libvirt/qemu
DST=/var/backups/kvmvms

LOCK=/var/lock/${0##*/}
if ! mkdir $LOCK 2>/dev/null; then
	echo Already running or stale lock ${LOCK} exists. >&2
	exit 1
fi
trap -- "rmdir $LOCK" EXIT

[[ -d ${DIR} ]] || exit 1
[[ -d ${DST} ]] || mkdir -p ${DST}

for vm in $(virsh list --name); do
	unset imgs
	unset imgsnew

	echo "-----------------------------------------------------------------------------"
	echo "Backup KVM guest '${vm}'"

	# Liste der Plattennamen und Imagepfade holen
	declare -A imgs
	eval $(virsh domblklist ${vm} --details | awk '/disk/ {print "imgs["$3"]="$4}')

	# testen, ob bereits ein Image-File mit .backup vorhanden ist
	for img in ${imgs[@]}; do
		# Endung wegschneiden, da Snapshot mit Basename + .backup angelegt wird
		img=${img%@(.img|.qcow2)}
		[ -f ${img}.backup ] && echo ${img}.backup aus VM ${vm} ist bereits vorhanden && continue 2
	done

	# Snapshots aller Platten der VM erzeugen
	virsh snapshot-create-as ${vm} backup --disk-only --atomic --no-metadata --quiesce
	
	# Namen der erstellen Backup-Files für späteres Löschen merken
	declare -A imgsbackup
	eval $(virsh domblklist ${vm} --details | awk '/disk/ {print "imgsbackup["$3"]="$4}')

	# ursprüngliche Images der VM wegkopieren
	for img in ${imgs[@]}; do
		mkdir -p ${DST}/${vm}/
		rsync --sparse ${img} ${DST}/${vm}/
	done

	# Snapshot in ursprüngliche Platten einarbeiten
	for disc in ${!imgs[@]}; do
		virsh blockcommit ${vm} ${disc} --active --wait --pivot
	done

	# testen, ob alle Platten wieder "original" sind
	declare -A imgsnew
	eval $(virsh domblklist ${vm} --details | awk '/disk/ {print "imgsnew["$3"]="$4}')
	for disc in ${!imgsnew[@]}; do
		[ ${imgs[$disc]} != ${imgsnew[$disc]} ] && echo Fehler beim Einarbeiten des Snapshots von  ${vm} ${disc} && continue 2
	done

	# löschen der nicht mehr benötigten Snapshots
	for img in ${imgsbackup[@]}; do
		fuser -s ${img} || rm ${img}
	done
	unset imgsbackup

	# VM-Definition ebenfalls sichern
    virsh dumpxml ${vm} > ${DST}/${vm}/domain.xml
done

# Inaktive VMs sichern
for vm in $(virsh list --name --inactive); do
    unset imgs
    echo "-----------------------------------------------------------------------------"
    echo "Backup KVM guest '${vm}'"

    # Liste der Plattennamen und Imagepfade holen
    declare -A imgs
    eval $(virsh domblklist ${vm} --details | awk '/disk/ {print "imgs["$3"]="$4}')
    
    # ursprüngliche Images der VM wegkopieren
    for img in ${imgs[@]}; do
        mkdir -p ${DST}/${vm}/
        if [ -f ${DST}/${vm}/$(basename ${img}) ]; then
        	rsync --inplace ${img} ${DST}/${vm}/
	else
        	rsync --sparse ${img} ${DST}/${vm}/
	fi
    done
    # VM-Definition ebenfalls sichern
    virsh dumpxml ${vm} > ${DST}/${vm}/domain.xml
done
exit 0
