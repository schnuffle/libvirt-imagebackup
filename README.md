# libvirt-imagebackup

Bash-Backup-Skript zum Sichern der VM-Images im laufenden Betrieb mit libvirt

Installation und Betrieb
------------------------

* Sicherstellen das bei allen zu sichernden VMs der QEMU Guest Agent aktiv ist, z.B. mit `virsh domtime "vm"` (siehe [QEMU Wiki](https://wiki.libvirt.org/page/Qemu_guest_agent))
* backup-vms.conf.dist nach /etc/backup-vms.conf kopieren und optional anpassen
* Snapshots für evtl. eingebundene Blockdevices im XML der VM deaktivieren: `<disk type='block' device='disk' snapshot='no'>`
* backup-vms.sh aufrufen und zuschauen

Check MK Agent
--------------

Der Sicherungsstatus lässt sich jetzt über [Check MK](https://mathias-kettner.de/check_mk.html)
auslesen. Die Datei checkmk-local/backup-vms nach /usr/lib/check-mk-agent/local kopieren und 
mit ausführenden rechten versehen. Im Anschluss in der Check MK Site die Dienste neu discovern.
