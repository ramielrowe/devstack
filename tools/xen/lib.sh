function install_xapi_plugins() {
  # get nova
  nova_zipball=$(echo $NOVA_REPO | sed "s:\.git$::;s:$:/zipball/$NOVA_BRANCH:g")
  wget $nova_zipball -O nova-zipball --no-check-certificate
  unzip -o nova-zipball  -d ./nova

  # install xapi plugins
  XAPI_PLUGIN_DIR=/etc/xapi.d/plugins/
  if [ ! -d $XAPI_PLUGIN_DIR ]; then
      # the following is needed when using xcp-xapi
      XAPI_PLUGIN_DIR=/usr/lib/xcp/plugins/
  fi
  cp -pr ./nova/*/plugins/xenserver/xenapi/etc/xapi.d/plugins/* $XAPI_PLUGIN_DIR
  chmod a+x ${XAPI_PLUGIN_DIR}*

  mkdir -p /boot/guest
}

# Helper to create networks
# Uses echo trickery to return network uuid
function create_network() {
    br=$1
    dev=$2
    vlan=$3
    netname=$4
    if [ -z $br ]
    then
        pif=$(xe_min pif-list device=$dev VLAN=$vlan)
        if [ -z $pif ]
        then
            net=$(xe network-create name-label=$netname)
        else
            net=$(xe_min network-list  PIF-uuids=$pif)
        fi
        echo $net
        return 0
    fi
    if [ ! $(xe_min network-list  params=bridge | grep -w --only-matching $br) ]
    then
        echo "Specified bridge $br does not exist"
        echo "If you wish to use defaults, please keep the bridge name empty"
        exit 1
    else
        net=$(xe_min network-list  bridge=$br)
        echo $net
    fi
}

function errorcheck() {
    rc=$?
    if [ $rc -ne 0 ]
    then
        exit $rc
    fi
}

# Helper to create vlans
function create_vlan() {
    dev=$1
    vlan=$2
    net=$3
    # VLAN -1 refers to no VLAN (physical network)
    if [ $vlan -eq -1 ]
    then
        return
    fi
    if [ -z $(xe_min vlan-list  tag=$vlan) ]
    then
        pif=$(xe_min pif-list  network-uuid=$net)
        # We created a brand new network this time
        if [ -z $pif ]
        then
            pif=$(xe_min pif-list  device=$dev VLAN=-1)
            xe vlan-create pif-uuid=$pif vlan=$vlan network-uuid=$net
        else
            echo "VLAN does not exist but PIF attached to this network"
            echo "How did we reach here?"
            exit 1
        fi
    fi
}

function clean_server() {
    CLEAN_TEMPLATES=$1
    # Shutdown all domU's that created previously
    clean_templates_arg=""
    if $CLEAN_TEMPLATES; then
        clean_templates_arg="--remove-templates"
    fi
    ./scripts/uninstall-os-vpx.sh $clean_templates_arg

    # Destroy any instances that were launched
    for uuid in `xe vm-list | grep -1 instance | grep uuid | sed "s/.*\: //g"`; do
        echo "Shutting down nova instance $uuid"
        xe vm-unpause uuid=$uuid || true
        xe vm-shutdown uuid=$uuid || true
        xe vm-destroy uuid=$uuid
    done

    # Destroy orphaned vdis
    for uuid in `xe vdi-list | grep -1 Glance | grep uuid | sed "s/.*\: //g"`; do
        xe vdi-destroy uuid=$uuid
    done
}

function wait_for_VM_to_halt() {
    while true
    do
        state=$(xe_min vm-list name-label="$1" power-state=halted)
        if [ -n "$state" ]
        then
            break
        else
            echo "Waiting for "$1" to finish installation..."
            sleep 20
        fi
    done
}

function create_vm_and_template(){

    GUEST_NAME=$1
    TNAME=$2
    SNAME_PREPARED=$3

    #
    # Install Ubuntu over network
    #

    # always update the preseed file, incase we have a newer one
    PRESEED_URL=${PRESEED_URL:-""}
    if [ -z "$PRESEED_URL" ]; then
        PRESEED_URL="${HOST_IP}/devstackubuntupreseed.cfg"
        HTTP_SERVER_LOCATION="/opt/xensource/www"
        if [ ! -e $HTTP_SERVER_LOCATION ]; then
            HTTP_SERVER_LOCATION="/var/www/html"
            mkdir -p $HTTP_SERVER_LOCATION
        fi
        cp -f $TOP_DIR/devstackubuntupreseed.cfg $HTTP_SERVER_LOCATION
        MIRROR=${MIRROR:-""}
        if [ -n "$MIRROR" ]; then
            sed -e "s,d-i mirror/http/hostname string .*,d-i mirror/http/hostname string $MIRROR," \
                -i "${HTTP_SERVER_LOCATION}/devstackubuntupreseed.cfg"
        fi
    fi

    # Update the template
    $TOP_DIR/scripts/install_ubuntu_template.sh $PRESEED_URL

    # create a new VM with the given template
    # creating the correct VIFs and metadata
    $TOP_DIR/scripts/install-os-vpx.sh -t "$UBUNTU_INST_TEMPLATE_NAME" -v $VM_BR -m $MGT_BR -p $PUB_BR -l $GUEST_NAME -r $OSDOMU_MEM_MB -k "flat_network_bridge=${VM_BR}"

    # wait for install to finish
    wait_for_VM_to_halt $GUEST_NAME

    # set VM to restart after a reboot
    vm_uuid=$(xe_min vm-list name-label="$GUEST_NAME")
    xe vm-param-set actions-after-reboot=Restart uuid="$vm_uuid"

    #
    # Prepare VM for DevStack
    #

    # Install XenServer tools, and other such things
    $TOP_DIR/prepare_guest_template.sh "$GUEST_NAME"

    # start the VM to run the prepare steps
    xe vm-start vm="$GUEST_NAME"

    # Wait for prep script to finish and shutdown system
    wait_for_VM_to_halt $GUEST_NAME

    # Make template from VM
    snuuid=$(xe vm-snapshot vm="$GUEST_NAME" new-name-label="$SNAME_PREPARED")
    xe snapshot-clone uuid=$snuuid new-name-label="$TNAME"
    
    return vm_uuid

}

function create_vm() {

    GUEST_NAME=$1
    TNAME=$2
    SNAME_PREPARED=$3

    templateuuid=$(xe template-list name-label="$TNAME")
    if [ -z "$templateuuid" ]; then
        vm_uuid = $(create_vm_and_template $GUEST_NAME $TNAME $SNAME_PREPARED)
    else
        #
        # Template already installed, create VM from template
        #
        vm_uuid = $(xe vm-install template="$TNAME" new-name-label="$GUEST_NAME")
    fi

    return vm_uuid;

}

#
# Find IP and optionally wait for stack.sh to complete
#

function find_ip_by_name() {
  local guest_name="$1"
  local interface="$2"
  local period=10
  max_tries=10
  i=0
  while true
  do
    if [ $i -ge $max_tries ]; then
      echo "Timed out waiting for devstack ip address"
      exit 11
    fi

    devstackip=$(xe vm-list --minimal \
                 name-label=$guest_name \
                 params=networks | sed -ne "s,^.*${interface}/ip: \([0-9.]*\).*\$,\1,p")
    if [ -z "$devstackip" ]
    then
      sleep $period
      ((i++))
    else
      echo $devstackip
      break
    fi
  done
}

function ssh_no_check() {
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$@"
}
