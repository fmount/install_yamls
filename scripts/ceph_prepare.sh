#!/bin/bash


TIMEOUT=${TIMEOUT:-120}
DELAY=${DELAY:-20}
POOLS=("volumes" "images" "backups")

function clean_host_data {
    ceph_data=$1

    if [ -z "$1" ]; then
        echo "Unable to clean host data: a path is required!"
        exit 1
    fi

    echo "Clean host ceph data"
    sudo rm -rf "$ceph_data"
    sudo systemctl disable ceph-osd-losetup.service
}

function clean_osd {
    sudo lvremove --force /dev/ceph_vg/ceph_lv_data
    sudo vgremove --force ceph_vg
    sudo pvremove --force /dev/loop2
    sudo losetup -d /dev/loop2
    sudo rm -f /var/lib/ceph-osd.img
}

function build_osd {
    sudo dd if=/dev/zero of=/var/lib/ceph-osd.img bs=1 count=0 seek=7G
    sudo losetup /dev/loop2 /var/lib/ceph-osd.img
    sudo pvcreate  /dev/loop2
    sudo vgcreate ceph_vg /dev/loop2
    sudo lvcreate -n ceph_lv_data -l +100%FREE ceph_vg
}


function enable_osd_systemd_service {

cat << EOF > /tmp/ceph-osd-losetup.service
[Unit]
Description=Ceph OSD losetup
After=syslog.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c '/sbin/losetup /dev/loop3 || \
/sbin/losetup /dev/loop2 /var/lib/ceph-osd.img ; partprobe /dev/loop2'
ExecStop=/sbin/losetup -d /dev/loop2
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF

sudo mv /tmp/ceph-osd-losetup.service /etc/systemd/system/
sudo systemctl enable ceph-osd-losetup.service

}

function usage() {
    # Display Help
    # ./prepare_ceph.sh
    echo "Prepare the host for a Ceph deployment."
    echo
    echo "Syntax: $0 [clean|build]" 1>&2;
    echo "Options:"
    echo "build     Clean the environment and rebuild the OSD data"
    echo "clean     Remove the OSD related data and remove /var/lib/ceph"
    echo
    echo "Examples"
    echo
    echo "> $0 build"
    echo
    echo "> $0 clean"
}


function ceph_is_ready {

    sleep $DELAY
    CEPH_TOOLS=$(oc get pods -l app=rook-ceph-tools -o name)
    echo "Waiting the cluster to be up"
    until [[ -n $(oc rsh $CEPH_TOOLS ceph -s | awk '/HEALTH_OK/ {print $2}') ]];
    do
        sleep 1
        echo -n .
        (( TIMEOUT-- ))
        [[ "$TIMEOUT" -eq 0 ]] && exit 1
    done
    echo
}

function create_pools {

    [ "${#POOLS[@]}" -eq 0 ] && return;

    CEPH_TOOLS=$(oc get pods -l app=rook-ceph-tools -o name)

    for pool in "${POOLS[@]}"; do
        oc rsh $CEPH_TOOLS ceph osd pool create $pool 4
        oc rsh $CEPH_TOOLS ceph osd pool application enable $pool rbd
    done
}

function create_secret {

    SECRET_NAME="$1"
    NAMESPACE="openstack"
    CEPH_TOOLS=$(oc get pods -l app=rook-ceph-tools -o name)

    TEMPDIR=`mktemp -d`
    trap 'rm -rf -- "$TEMPDIR"' EXIT
    echo 'Copying Ceph config files from the container to $TEMPDIR'
    oc rsh $CEPH_TOOLS ceph config generate-minimal-conf > $TEMPDIR/ceph.conf
    oc rsh $CEPH_TOOLS ceph auth export client.admin > $TEMPDIR/ceph.client.admin.keyring

    echo "Replacing openshift secret $SECRET_NAME"
    oc delete secret "$SECRET_NAME" 2>/dev/null || true -n $NAMESPACE
    oc create secret generic $SECRET_NAME --from-file=$TEMPDIR/ceph.conf --from-file=$TEMPDIR/ceph.client.admin.keyring -n $NAMESPACE
}

## MAIN

case "$1" in
    "clean")
        clean_osd
        clean_host_data "/var/lib/rook"
        ;;
    "build")
        build_osd
        enable_osd_systemd_service
        ;;
    "is_ready")
        ceph_is_ready
        ;;
    "pools")
        create_pools
        ;;
    "secret")
        create_secret "ceph-conf-files"
        ;;
    *)
        usage
        ;;
esac
