# libvirt-imagebackup

Bash-Backup-Skript zum Sichern der VM-Images im laufenden Betrieb mit libvirt

Installation und Betrieb
------------------------

Sicherstellen das bei allen zu sichernden VMs der QEMU Guest Agent aktiv ist.
(z.b. virsh domtime "vm") Mehr dazu gibt's im 
[QEMU Wiki|https://wiki.libvirt.org/page/Qemu_guest_agent].

backup-vms.conf.dist nach /etc kopieren und optional anpassen.
backup-vms.sh aufrufen und zuschauen

Check MK Agent
--------------

Der Sicherungsstatus lässt sich jetzt über [Check MK|https://mathias-kettner.de/check_mk.html] 
auslesen. Die Datei checkmk-local/backup-vms nach /usr/lib/check-mk-agent/local kopieren und 
mit ausführenden rechten versehen. Im Anschluss in der Check MK Site die Dienste neu discovern.
