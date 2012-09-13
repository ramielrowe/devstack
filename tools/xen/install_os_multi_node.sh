#!/bin/bash

# This script is a level script
# It must be run on a XenServer or XCP machine
#
# It creates a DomU VM that runs OpenStack services
#
# For more details see: README.md

# Exit on errors
set -o errexit
# Echo commands
set -o xtrace

# Abort if localrc is not set
if [ ! -e ../../localrc ]; then
    echo "You must have a localrc with ALL necessary passwords defined before proceeding."
    echo "See the xen README for required passwords."
    exit 1
fi

# This directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Source lower level functions
. $TOP_DIR/../../functions

# Include onexit commands
. $TOP_DIR/scripts/on_exit.sh

# Source Xen specific functions
. functions


#
# Get Settings
#

# Source params - override xenrc params in your localrc to suit your taste
source xenrc

#
# Prepare Dom0
# including installing XenAPI plugins
#

cd $TOP_DIR
if [ -f ./master ]
then
    rm -rf ./master
    rm -rf ./nova
fi

install_nova_plugins

#
# Configure Networking
#

# Create host, vm, mgmt, pub networks on XenServer
VM_NET=$(create_network "$VM_BR" "$VM_DEV" "$VM_VLAN" "vmbr")
errorcheck
MGT_NET=$(create_network "$MGT_BR" "$MGT_DEV" "$MGT_VLAN" "mgtbr")
errorcheck
PUB_NET=$(create_network "$PUB_BR" "$PUB_DEV" "$PUB_VLAN" "pubbr")
errorcheck

# Create vlans for vm and management
create_vlan $PUB_DEV $PUB_VLAN $PUB_NET
create_vlan $VM_DEV $VM_VLAN $VM_NET
create_vlan $MGT_DEV $MGT_VLAN $MGT_NET

# Get final bridge names
if [ -z $VM_BR ]; then
    VM_BR=$(xe_min network-list  uuid=$VM_NET params=bridge)
fi
if [ -z $MGT_BR ]; then
    MGT_BR=$(xe_min network-list  uuid=$MGT_NET params=bridge)
fi
if [ -z $PUB_BR ]; then
    PUB_BR=$(xe_min network-list  uuid=$PUB_NET params=bridge)
fi

# dom0 ip, XenAPI is assumed to be listening
HOST_IP=${HOST_IP:-`ifconfig xenbr0 | grep "inet addr" | cut -d ":" -f2 | sed "s/ .*//"`}

setup_ip_forwarding

clean_xenserver

#
# Create Ubuntu VM template
# and/or create VM from template
#

HEAD_MGT_IP=${HEAD_MGT_IP:-172.16.100.57}
COMPUTE_MGT_IP_BASE=${COMPUTE_MGT_IP:-172.16.100.}
COMMON_VARS="$STACKSH_PARAMS MYSQL_HOST=$HEAD_MGT_IP RABBIT_HOST=$HEAD_MGT_IP GLANCE_HOSTPORT=$HEAD_MGT_IP:9292 FLOATING_RANGE=$FLOATING_RANGE"

GUEST_NAME=${GUEST_NAME:-"DevStackHeadNode"}
TNAME="devstack_template"
SNAME_PREPARED="template_prepared"
SNAME_FIRST_BOOT="before_first_boot"

create_vm "$GUEST_NAME" "$TNAME" "$SNAME_PREPARED"

NUM_COMPUTES=${NUM_COMPUTES:-2}

for i in {1..NUM_COMPUTES} do
    create_vm "DevStackCompute$i" "$TNAME" "$SNAME_PREPARED"
done

#
# Inject DevStack inside VM disk
#
build_xva "$GUEST_NAME" $HEAD_MGT_IP 1 "ENABLED_SERVICES=g-api,g-reg,key,n-api,n-sch,n-vnc,horizon,mysql,rabbit"

for i in {1..NUM_COMPUTES} do
    last_octet=57+$i;
    build_xva COMPUTENODE "$COMPUTE_MGT_IP_BASE.$last_octet" 0 "ENABLED_SERVICES=n-cpu,n-net,n-api"
done

# create a snapshot before the first boot
# to allow a quick re-run with the same settings
xe vm-snapshot vm="$GUEST_NAME" new-name-label="$SNAME_FIRST_BOOT"


#
# Run DevStack VM
#
xe vm-start vm="$GUEST_NAME"


#
# Find IP and optionally wait for stack.sh to complete
#

# Note the XenServer needs to be on the chosen
# network, so XenServer can access Glance API
if [ $HOST_IP_IFACE == "eth2" ]; then
    DOMU_IP=$MGT_IP
    if [ $MGT_IP == "dhcp" ]; then
        DOMU_IP=$(find_ip_by_name $GUEST_NAME 2)
    fi
else
    DOMU_IP=$PUB_IP
    if [ $PUB_IP == "dhcp" ]; then
        DOMU_IP=$(find_ip_by_name $GUEST_NAME 3)
    fi
fi

# Launch the head node - headnode uses a non-ip domain name,
# because rabbit won't launch with an ip addr hostname :(
build_xva HEADNODE $HEAD_PUB_IP $HEAD_MGT_IP 1 "ENABLED_SERVICES=g-api,g-reg,key,n-api,n-sch,n-vnc,horizon,mysql,rabbit"

# If we have copied our ssh credentials, use ssh to monitor while the installation runs
WAIT_TILL_LAUNCH=${WAIT_TILL_LAUNCH:-1}
COPYENV=${COPYENV:-1}
if [ "$WAIT_TILL_LAUNCH" = "1" ]  && [ -e ~/.ssh/id_rsa.pub  ] && [ "$COPYENV" = "1" ]; then
    echo "We're done launching the vm, about to start tailing the"
    echo "stack.sh log. It will take a second or two to start."
    echo
    echo "Just CTRL-C at any time to stop tailing."

    # wait for log to appear
    while ! ssh_no_check -q stack@$DOMU_IP "[ -e run.sh.log ]"; do
        sleep 10
    done

    # output the run.sh.log
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no stack@$DOMU_IP 'tail -f run.sh.log' &
    TAIL_PID=$!

    function kill_tail() {
        kill -9 $TAIL_PID
        exit 1
    }
    # Let Ctrl-c kill tail and exit
    trap kill_tail SIGINT

    # ensure we kill off the tail if we exit the script early
    # for other reasons
    add_on_exit "kill -9 $TAIL_PID || true"

    # wait silently until stack.sh has finished
    set +o xtrace
    while ! ssh_no_check -q stack@$DOMU_IP "tail run.sh.log | grep -q 'stack.sh completed in'"; do
        sleep 10
    done
    set -o xtrace

    # kill the tail process now stack.sh has finished
    kill -9 $TAIL_PID

    # check for a failure
    if ssh_no_check -q stack@$DOMU_IP "grep -q 'stack.sh failed' run.sh.log"; then
        exit 1
    fi
    echo "################################################################################"
    echo ""
    echo "All Finished!"
    echo "You can visit the OpenStack Dashboard"
    echo "at http://$DOMU_IP, and contact other services at the usual ports."
else
    echo "################################################################################"
    echo ""
    echo "All Finished!"
    echo "Now, you can monitor the progress of the stack.sh installation by "
    echo "tailing /opt/stack/run.sh.log from within your domU."
    echo ""
    echo "ssh into your domU now: 'ssh stack@$DOMU_IP' using your password"
    echo "and then do: 'tail -f /opt/stack/run.sh.log'"
    echo ""
    echo "When the script completes, you can then visit the OpenStack Dashboard"
    echo "at http://$DOMU_IP, and contact other services at the usual ports."
fi
