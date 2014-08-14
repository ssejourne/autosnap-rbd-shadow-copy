#!/bin/bash

# Snapshot script for Ceph RBD and Samba vfs shadow_copy2
# Written by Laurent Barbe <laurent+autosnap@ksperis.com>
# Version 0.1 - 2013-08-09
#
# Install this file and config file in /etc/ceph/scripts/
# Edit autosnap.conf
#
# Add in crontab :
# 00 0    * * *   root    /bin/bash /etc/ceph/scripts/autosnap.sh
#
# Add in your smb.conf in global or specific share section :
# vfs objects = shadow_copy2
# shadow:snapdir = .snapshots
# shadow:sort = desc

# Librement inspire de https://github.com/ksperis/autosnap-rbd-shadow-copy/blob/master/autosnap.sh
# TODO
#  * manage different retention period

TMPFILE=/tmp/`basename ${0}`.${$}

exec 3>&1
exec 1>$TMPFILE

# Config file
configfile=/etc/ceph/scripts/autosnap.conf
if [ ! -f $configfile ]; then
	echo "Config file not found $configfile"
	exit 0
fi
source $configfile


makesnapshot() {
	share=$1
	nfs_gw=$2
	
	if [[ ! -z $nfs_gw ]]
	then
		remote_cmd="ssh -q $nfs_gw"
	else
		remote_cmd=""
	fi

	rbdpool=`$remote_cmd find /dev/rbd -name $share | awk -v FS='/' '{ print $4}'`
	if [[ -z $rbdpool ]]; then
		echo "ERROR: no pool find for $share ($nfs_gw)"
		return
	fi
	
	snapname=`date -u +GMT-%Y.%m.%d-%H.%M.%S-autosnap`

	echo "* Create snapshot for $share: @$snapname ($nfs_gw)"
	[[ "$useenhancedio" = "yes" ]] && {
		$remote_cmd /sbin/sysctl dev.enhanceio.$share.do_clean=1
		while [[ `$remote_cmd cat /proc/sys/dev/enhanceio/$share/do_clean` == 1 ]]; do sleep 1; done
	}
	$remote_cmd mountpoint -q $sharedirectory/$share \
		&& $remote_cmd  sudo sync \
		&& echo -n "synced, " \
		&& $remote_cmd sudo xfs_freeze -f $sharedirectory/$share \
		&& [[ "$useenhancedio" = "yes" ]] && {
				ssh -q $nfs_gw sudo /sbin/sysctl dev.enhanceio.$share.do_clean=1
				while [[ `$remote_cmd cat /proc/sys/dev/enhanceio/$share/do_clean` == 1 ]]; do sleep 1; done
				echo -n "wb cache cleaned, "
			} \
			|| /bin/echo -n "no cache, " \
		&& $remote_cmd sudo rbd --id=$id --keyring=$keyring snap create $rbdpool/$share@$snapname \
		&& echo "snapshot created."
	$remote_cmd sudo xfs_freeze -u $sharedirectory/$share

}


mountshadowcopy() {
	share=$1
	nfs_gw=$2
	
	if [[ ! -z $nfs_gw ]]
	then
		remote_cmd="ssh -q $nfs_gw"
	else
		remote_cmd=""
	fi

	rbdpool=`$remote_cmd find /dev/rbd -name $share | awk -v FS='/' '{ print $4}'`
	if [[ -z $rbdpool ]]; then
		echo "ERROR: no pool find for $share ($nfs_gw)"
		return
	fi
	
	# GET ALL EXISTING SNAPSHOT ON RBD
	snapcollection=$($remote_cmd sudo rbd snap ls $rbdpool/$share | awk '{print $2}' | grep -- 'GMT-.*-autosnap$' | sort | sed 's/-autosnap$//g')

	# TODAY
	shadowcopylist=$(echo "$snapcollection" | grep `date -u +GMT-%Y.%m.%d-` | head -n 1)
	
	# LAST 6 DAYS
	for i in `seq 1 3`; do
		shadowcopylist="$shadowcopylist
$(echo "$snapcollection" | grep `date -u +GMT-%Y.%m.%d- -d "$i day ago"` | head -n 1)"
	done
	
	# LAST 4 WEEKS
#	for i in `seq 1 2`; do
#		shadowcopylist="$shadowcopylist
#$(echo "$snapcollection" | grep `date -u +GMT-%Y.%m.%d- -d "$i week ago"` | head -n 1)"
#	done
	
	# LAST 5 MONTHS
#	for i in `seq 1 2`; do
#		shadowcopylist="$shadowcopylist
#$(echo "$snapcollection" | grep `date -u +GMT-%Y.%m.%d- -d "$i month ago"` | head -n 1)"
#	done

	# Shadow copy to mount
	# echo -e "* Shadow Copy to mount for $nfs_gw $rbdpool/$share :\n"$shadowcopylist | sed 's/^$/-/g'

	# GET MOUNTED SNAP
	$remote_cmd test -d $sharedirectory/$share/.snapshots || { 
		echo "Snapshot directory $nfs_gw $sharedirectory/$share/.snapshots does not exist. Please create it before run." && return 
	}
	snapmounted=`$remote_cmd sudo ls $sharedirectory/$share/.snapshots | sed 's/^@//g'`

	# Umount Snapshots not selected in shadowcopylist
	for snapshot in $snapmounted; do
		mountdir=$sharedirectory/$share/.snapshots/@$snapshot
		echo "$shadowcopylist" | grep -q "$snapshot" || {
			$remote_cmd sudo umount $mountdir || ssh -q $nfs_gw sudo umount -l $mountdir
			$remote_cmd sudo rmdir $mountdir
			$remote_cmd sudo rbd unmap /dev/rbd/$rbdpool/$share@$snapshot-autosnap
			# And delete it
			echo -e "* Delete snapshot for $share: @$snapname"
			$remote_cmd sudo rbd snap rm $rbdpool/$share@$snapshot-autosnap
		}
	done
	
	# Delete old snapshots unmounted
	snapcollection=$($remote_cmd sudo rbd snap ls $rbdpool/$share | awk '{print $2}' | grep -- 'GMT-.*-autosnap$' | sort | sed 's/-autosnap$//g')
	for snapshot in $snapcollection; do
		echo "$shadowcopylist" | grep -q "$snapshot" || {
			echo -e "* Delete old snapshot for $share: @$snapname"
			$remote_cmd sudo rbd snap rm $rbdpool/$share@$snapshot-autosnap
		}
	done
	
	if [[ "$mountshadowcopyenable" = "yes" ]]; then
		# Mount snap in $shadowcopylist not already mount
		for snapshot in $shadowcopylist; do
			mountdir=$sharedirectory/$share/.snapshots/@$snapshot
			echo $mountdir
			$remote_cmd mountpoint -q $mountdir || {
				$remote_cmd test -d $mountdir ||  $remote_cmd sudo mkdir $mountdir 
				$remote_cmd sudo rbd showmapped | awk '{print $4}' | grep "^$" || $remote_cmd sudo rbd map $rbdpool/$share@$snapshot-autosnap
				$remote_cmd sudo mount $mntoptions /dev/rbd/$rbdpool/$share@$snapshot-autosnap $mountdir
			}
		done
	fi

}


if [[ "$snapshotenable" = "yes" ]]; then
	for share in $sharelist; do
		flag_snap=false
		if [[ ! -z $NFS_GW_LIST ]]
		then
			for remote_gw in $NFS_GW_LIST ; do
				ssh -q $remote_gw "df -t xfs" | grep -q $share
				if [[ $? -eq 0 ]]
				then
					makesnapshot $share $remote_gw
					flag_snap=true
				fi
			done
		else
			makesnapshot $share ""
			flag_snap=true
		fi
		
		$flag_snap || echo "ERROR: no snapshot done for $share"
	done
fi

echo

[[ "$snapshotenable" = "yes" ]] && sleep 60

for share in $sharelist; do
	if [[ ! -z $NFS_GW_LIST ]]
	then		
		for remote_gw in $NFS_GW_LIST ; do
			ssh -q $remote_gw "df -t xfs" | grep -q $share
			if [[ $? -eq 0 ]]
			then
				mountshadowcopy $share $remote_gw
			fi
		done
	else
		mountshadowcopy $share ""
	fi
done

exec 1>&3
exec 3>&-

if [ $EMAIL ] ; then
        mail -s "$(echo -e "CEPH autosnap Report - `date +"%Y-%m-%d"`")" $DEST_EMAIL < $TMPFILE
else
        cat $TMPFILE
fi

rm $TMPFILE

