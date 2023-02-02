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
    CEPH_TOOLS=$(oc get pods -l app=rook-ceph-tools -o name -n rook-ceph)
    echo "Waiting the cluster to be up"
    until [[ -n $(oc -n rook-ceph rsh $CEPH_TOOLS ceph -s | awk '/HEALTH_OK/ {print $2}') ]];
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


function build_caps {
    local CAPS=""
    for pool in "${POOLS[@]}"; do
        caps="allow rwx pool="$pool
        CAPS+=$caps,
    done
    echo "${CAPS::-1}"
}

function create_key {
    CEPH_TOOLS=$(oc get pods -l app=rook-ceph-tools -o name)
    local client=$1
    local caps
    local osd_caps

    if [ "${#POOLS[@]}" -eq 0 ]; then
        osd_caps="allow *"
    else
        caps=$(build_caps)
        osd_caps="allow class-read object_prefix rbd_children, $caps"
    fi
    # do not log the key if exists
    oc rsh ${CEPH_TOOLS} ceph auth get-or-create "$client" mgr "allow rw" mon "allow r" osd "$osd_caps" >/dev/null
}


function create_secret {

    SECRET_NAME="$1"
    NAMESPACE="openstack"

    CEPH_TOOLS=$(oc get pods -l app=rook-ceph-tools -o name)
    client="client.openstack"

    TEMPDIR=`mktemp -d`
    trap 'rm -rf -- "$TEMPDIR"' EXIT
    echo 'Copying Ceph config files from the container to $TEMPDIR'
    oc rsh $CEPH_TOOLS ceph config generate-minimal-conf > $TEMPDIR/ceph.conf
    create_key "$client"

    echo 'Copying OpenStack keyring from the container to $TEMPDIR'
    oc rsh ${CEPH_TOOLS} ceph auth export "$client" -o /etc/ceph/ceph.$client.keyring >/dev/null
    oc rsync ${CEPH_TOOLS}:/etc/ceph/ceph.$client.keyring $TEMPDIR
    cat $TEMPDIR/ceph.conf
    cat $TEMPDIR/ceph.$client.keyring

    echo "Replacing openshift secret $SECRET_NAME"
    oc delete secret "$SECRET_NAME" -n $NAMESPACE 2>/dev/null || true
    oc create secret generic $SECRET_NAME --from-file=$TEMPDIR/ceph.conf --from-file=$TEMPDIR/ceph.$client.keyring -n $NAMESPACE
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
