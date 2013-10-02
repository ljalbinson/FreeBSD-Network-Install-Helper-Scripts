#!/bin/sh

###################################################################
# Script:	zfsrootinstall.sh                                 #
# Parameters:	installation disk is DISK0 - left side of mirror  #
#		installation disk is DISK1 - right side of mirror #
#		root password is ROOTPASS  - in encrypted form    #
#		continent in CONT          - from FreeBSD list    #
#		city in CITY               - from FreeBSD list    #
###################################################################

DISK0=da0
DISK1=da1
IFACE=em0
ROOTPASS='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
CONT=Europe
CITY=London
ISONAME='FreeBSD-9.1-RELEASE-amd64-dvd1.iso'

#################################################################
# Rudimentary check to prevent installation over running system #
#################################################################

dlv=`/sbin/sysctl -n vfs.nfs.diskless_valid 2> /dev/null`
if [ ${dlv:=0} -eq 0 ]; then
	echo "+++ Not running diskless, stopping ..."
	exit -1;
fi

########################################################
# Creates new GPT on disk (does destroy as precaution) #
########################################################

gpart destroy -F ${DISK0}
gpart destroy -F ${DISK1}
gpart create -s GPT ${DISK0}
gpart create -s GPT ${DISK1}
gpart add -t freebsd-boot -l bootcode0 -s 128k ${DISK0}
gpart add -t freebsd-boot -l bootcode1 -s 128k ${DISK1}
gpart add -t freebsd-zfs -l sys0 ${DISK0}
gpart add -t freebsd-zfs -l sys1 ${DISK1}
gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 ${DISK0}
gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 ${DISK1}
zpool create -f -o cachefile=/tmp/zpool.cache -m none sys mirror gpt/sys0 gpt/sys1
zfs set mountpoint=none sys
zfs set checksum=fletcher4 sys
zfs set atime=off sys
zfs create sys/ROOT
zfs create -o mountpoint=/mnt sys/ROOT/default
zpool set bootfs=sys/ROOT/default sys
mkdir -p /mnt/boot/zfs
cp /tmp/zpool.cache /mnt/boot/zfs

############################################################
# Mount distribution ISO on /tmp/mnt, checking for errors #
############################################################

mdno=`/sbin/mdconfig -f /usr/local/dist/${ISONAME}`
if [ $? -ne 0 ]; then
	echo "+++ mdconfig failed"
	exit -1
fi
mkdir -p /tmp/mnt
/sbin/mount -r -t cd9660 /dev/${mdno} /tmp/mnt
if [ $? -ne 0 ]; then
	echo "+++ mount failed"
	exit -1
fi

########################
# Install Distribution #
########################

cd /tmp/mnt/usr/freebsd-dist
for i in base.txz doc.txz games.txz kernel.txz lib32.txz src.txz; do
	tar --unlink -xpJf ${i} -C /mnt
done

#################################################################
# Set up initial /boot/loader.conf, /etc/rc.conf and /etc/fstab #
#################################################################

cat << EOF >> /mnt/boot/loader.conf
zfs_load=YES
vfs.root.mountfrom="zfs:sys/ROOT/default"
vfs.zfs.prefetch_disable=1
EOF

cat << EOF >> /mnt/etc/rc.conf
zfs_enable=YES
EOF

:> /mnt/etc/fstab

############################################################################
# Extract our DHCP assigned IP and set it as the static address in rc.conf #
# Also set up hostname, default route and DNS resolver                     #
############################################################################

IPADDR=`ifconfig $IFACE inet | grep inet | awk '{ print $2 ; }'`
echo hostname=\"`host $IPADDR | awk '{ print $5 ; }' | sed 's/\.$//'`\" >>/mnt/etc/rc.conf
echo ifconfig_$IFACE=\"inet `ifconfig $IFACE inet | grep inet | awk '{ print $2 ; }'` netmask 255.255.255.0\" >>/mnt/etc/rc.conf
echo defaultrouter=\"`netstat -rn -f inet | grep '^default' | awk '{ print $2 ; }'`\" >>/mnt/etc/rc.conf
cp /etc/resolv.conf /mnt/etc/resolv.conf

############################################
# Shorten auto-boot delay to 1             #
# Enable ssh with root access              #
# Trim motd                                #
# If in ESXi environment set kern.hz to 50 #
# Set root password                        #
# Set timezone                             #
# Create swap space                        #
############################################

echo "autoboot_delay=1" >>/mnt/boot/loader.conf
echo 'sshd_enable="YES"' >>/mnt/etc/rc.conf
sed -e 's/#PermitRootLogin no/PermitRootLogin yes/' </mnt/etc/ssh/sshd_config >/tmp/sshd_config
install -m 644 -o root -g wheel /tmp/sshd_config /mnt/etc/ssh/sshd_config
head -4 /mnt/etc/motd >/tmp/motd
install -m 644 -o root -g wheel /tmp/motd /mnt/etc/motd
if [ `pciconf -lv | grep VMware | wc -l` != 0 ]; then
	echo "kern.hz=50" >>/mnt/boot/loader.conf
fi
awk -v ROOTPASS="${ROOTPASS}" 'BEGIN{FS=":";OFS=":"}/^root/{$2=ROOTPASS}{print}' /mnt/etc/master.passwd > /tmp/master.passwd
install -m 600 -o root -g wheel /tmp/master.passwd /mnt/etc/master.passwd
rm -f /tmp/master.passwd
pwd_mkdb -d /mnt/etc /mnt/etc/master.passwd
tzsetup -C /mnt $CONT/$CITY
zfs create -V 1G -o org.freebsd:swap=on -o checksum=off -o sync=disabled -o primarycache=none -o secondarycache=none sys/swap
echo "/dev/zvol/sys/swap none swap sw 0 0" >>/mnt/etc/fstab

########################################################################
# Unmount newly installed root and set mount type to legacy and reboot #
########################################################################

zfs umount -a
zfs set mountpoint=legacy sys/ROOT/default
reboot
