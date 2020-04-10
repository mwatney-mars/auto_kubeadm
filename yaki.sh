#!/bin/bash

# Define script path 
SCRIPT_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )/"

# Preset Values ## User will prompted to confirm / change
KUBERNETES_VERSION="1.17.4-00"
INSTANCE_NAME_SUFIX="test"
INSTANCE_IMAGE="debian-9-drawfork-v20200207"
INSTANCE_MACHINE_TYPE="n1-standard-2"
GCLOUD_ZONE="europe-west3-c"
QTD_NODES="3"

# Default values
INSTANCE_NAME_PREFIX="yaki-"
STARTUP_SCRIPT_PATH="startup-script/"
STARTUP_SCRIPT="install_prereqs.sh"
CALICO_MANIFEST="https://docs.projectcalico.org/v3.11/manifests/calico.yaml"
DELETE_OLD_CLUSTER="yes"
LOGFILE="$SCRIPT_PATH""log/auto_kubeadm.log"

unknown_os ()
{
  echo "Unfortunately, your operating system distribution and version are not supported by this script."
  echo
  exit 1
}

detect_os ()
{
  ## NOT USED AT THIS POINT. FOR FUTURE USE.
  if [[ ( -z "${os}" ) && ( -z "${dist}" ) ]]; then
    # some systems dont have lsb-release yet have the lsb_release binary and
    # vice-versa
    if [ -e /etc/lsb-release ]; then
      . /etc/lsb-release

      if [ "${ID}" = "raspbian" ]; then
        os=${ID}
        dist=`cut --delimiter='.' -f1 /etc/debian_version`
      else
        os=${DISTRIB_ID}
        dist=${DISTRIB_CODENAME}

        if [ -z "$dist" ]; then
          dist=${DISTRIB_RELEASE}
        fi
      fi

    elif [ `which lsb_release 2>/dev/null` ]; then
      dist=`lsb_release -c | cut -f2`
      os=`lsb_release -i | cut -f2 | awk '{ print tolower($1) }'`

    elif [ -e /etc/debian_version ]; then
      # some Debians have jessie/sid in their /etc/debian_version
      # while others have '6.0.7'
      os=`cat /etc/issue | head -1 | awk '{ print tolower($1) }'`
      if grep -q '/' /etc/debian_version; then
        dist=`cut --delimiter='/' -f1 /etc/debian_version`
      else
        dist=`cut --delimiter='.' -f1 /etc/debian_version`
      fi

    else
      unknown_os
    fi
  fi

  if [ -z "$dist" ]; then
    unknown_os
  fi

  # remove whitespace from OS and dist name
  os="${os// /}"
  dist="${dist// /}"

  echo "Detected operating system as $os/$dist."
  echo
    
}


function define_instances_name ()
{
  INSTANCE_NAME="$INSTANCE_NAME_PREFIX""$INSTANCE_NAME_SUFIX"
}

function check_cmd_arguments ()
{
  for arg in "$@"
  do
      if [ "$arg" == "--delete" ] || [ "$arg" == "-d" ]
      then
          echo "Deleting previous cluster with "$INSTANCE_NAME" PREFIX"
          echo
          
          read -p "Continue (y/n)? " choice
          case "$choice" in 
            y|Y ) echo;check_if_delete_cluster;quit;;
            n|N ) quit;;
            * ) echo "invalid";;
          esac
      fi

      if [ "$arg" == "--verbose" ] || [ "$arg" == "-v" ]
      then
        echo "To be implemented."
        quit
      fi      
  done
}

function prep_startup_script ()
{
  STARTUP_SCRIPT_PATH="$SCRIPT_PATH""$STARTUP_SCRIPT_PATH"
  sed "2 aKUBERNETES_VERSION=\"$KUBERNETES_VERSION\"" "$STARTUP_SCRIPT_PATH"base > "$STARTUP_SCRIPT_PATH""$STARTUP_SCRIPT"
}

function quit ()
{
  exit
}

function pause ()
{
   read -p "$*"
}

function add_ssh_key ()
{
  echo "Adding your ssh-key to the authentication agent"
  echo

  if [ -f ~/.ssh/google_compute_engine ]; then
    eval `ssh-agent -s` > /dev/null 2>&1
    ssh-add ~/.ssh/google_compute_engine
  else  
    echo "Your GCP SSH key don't exist. Let's create it!"
    echo
    pause 'Press [Enter] key to continue...'
    gcloud compute config-ssh  
    ssh-add ~/.ssh/google_compute_engine
  fi

  if [ $? -eq 0 ]; then
    echo ""
  else
    echo
    echo "Ops, failed to add your ssh-key to the authentication agent. Check your passphrase."
    quit
  fi
}

function setup_logs ()
{
  mkdir ${LOGFILE%/*}/ > /dev/null 2>&1
}

function check_if_delete_cluster ()
{
  if [ "$DELETE_OLD_CLUSTER" == "yes" ]; then
    echo "Checking if there are existent compute instances that need to be removed"
    echo
    INSTANCES_LIST=$(gcloud compute instances list --filter="$INSTANCE_NAME" --format='value(NAME)')
    if [ -z "$INSTANCES_LIST" ]; then
      echo "Nothing to remove"
      echo
    else
      echo "Found something:"
      echo
      echo "$INSTANCES_LIST"
      echo 
      echo "Removing existend instances (it may take a while)"
      echo
      gcloud compute instances list --filter="$INSTANCE_NAME" --format='value(NAME)' | xargs -I {} gcloud compute instances delete {} --zone $GCLOUD_ZONE --quiet
      sleep 10
    fi
  else
    i=1
    while [ $i -lt "$QTD_NODES" ]; do
      INSTANCE_CHECK=$(gcloud compute instances list | awk '{ print $1 }' | grep "$INSTANCE_NAME-${i}")
      if [ "$INSTANCE_CHECK" == "$INSTANCE_NAME-${i}" ]; then
        echo "ERROR: Oh I can't proceed. have compute instances using the same prefix defined on INSTANCE_NAME ($INSTANCE_NAME). 
        Chose a different prefix or change DELETE_OLD_CLUSTER to yes if you allow me to delete it (DELETE_OLD_CLUSTER = $DELETE_OLD_CLUSTER)"
        exit 1
      fi
        i=$((i + 1))
    done
  fi  
}

function prompt_cluster_specs ()
{
  read -p "Desired Kubernetes Version [$KUBERNETES_VERSION]: " getKUBERNETES_VERSION
  KUBERNETES_VERSION=${getKUBERNETES_VERSION:-$KUBERNETES_VERSION}

  read -p "Desired Kubernetes Version [$INSTANCE_NAME_SUFIX]: " getINSTANCE_NAME_SUFIX
  INSTANCE_NAME_SUFIX=${getINSTANCE_NAME_SUFIX:-$INSTANCE_NAME_SUFIX}

  read -p "Desired Kubernetes Version [$INSTANCE_IMAGE]: " getINSTANCE_IMAGE
  INSTANCE_IMAGE=${getINSTANCE_IMAGE:-$INSTANCE_IMAGE}

  read -p "Desired Kubernetes Version [$INSTANCE_MACHINE_TYPE]: " getINSTANCE_MACHINE_TYPE
  INSTANCE_MACHINE_TYPE=${getINSTANCE_MACHINE_TYPE:-$INSTANCE_MACHINE_TYPE}

  read -p "Desired Kubernetes Version [$GCLOUD_ZONE]: " getGCLOUD_ZONE
  GCLOUD_ZONE=${getGCLOUD_ZONE:-$GCLOUD_ZONE}

  read -p "Desired Kubernetes Version [$QTD_NODES]: " getQTD_NODES
  QTD_NODES=${getQTD_NODES:-$QTD_NODES}

}

function create_instances ()
{
  echo "Creating new compute instances"
  echo
  i=1
  while [ $i -le "$QTD_NODES" ]; do
    # gcloud compute instances create $INSTANCE_NAME-${i} \
    #   --async \
    #   --boot-disk-size 100GB \
    #   --boot-disk-type=pd-ssd \
    #   --can-ip-forward \
    #   --image=$INSTANCE_IMAGE \
    #   --image-project=eip-images \
    #   --machine-type $INSTANCE_MACHINE_TYPE \
    #   --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    #   --zone $GCLOUD_ZONE \
    #   --metadata-from-file startup-script=$STARTUP_SCRIPT_PATH""$STARTUP_SCRIPT >> $LOGFILE 2>&1

    echo $INSTANCE_NAME-${i}

    if [ $? -ne 0 ]; then
      read -p  "An error ocurred while creating your instances, do you want to check execution logs? (y/N)? " choice

      case "$choice" in 
        y|Y ) echo;cat $LOGFILE;;
        n|N ) quit;;
        * ) quit;;
      esac
      quit
    fi      

    echo "$INSTANCE_NAME-${i} created"
    i=$((i + 1))
  done
}

function check_master_readiness ()
{
  echo
  echo "Checking if Master node is Ready (Be patient, we are injecting the startup_script)"
  echo
  i=1
  READINESS=false
  while [ $READINESS != true ]; do
    VAR=$(gcloud compute ssh $INSTANCE_NAME-1 --zone $GCLOUD_ZONE --command "grep PREREQSDONE /var/log/daemon.log" 2> /dev/null)
    if [ -n "$VAR" ]; then 
      echo
      echo "OK! Master Node ($INSTANCE_NAME-1) is Ready"
      echo

      ### Adding user to docker group 
      gcloud compute ssh $INSTANCE_NAME-1 --zone $GCLOUD_ZONE --command "sudo groupadd docker; sudo usermod -aG docker $USER" >> $LOGFILE 2>&1

      READINESS=true
    else 
      echo "$INSTANCE_NAME-1 Not Ready..."
      sleep 15
    fi
  done
}

function init_master ()
{
  ### Initialize cluster on node 0
  echo "Initializing Master Node"
  echo
  gcloud compute ssh $INSTANCE_NAME-1 --zone $GCLOUD_ZONE --command "sudo kubeadm init --pod-network-cidr=192.168.0.0/16" >> $LOGFILE 2>&1

  gcloud compute ssh $INSTANCE_NAME-1 --zone $GCLOUD_ZONE --command "mkdir -p $HOME/.kube; sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config; sudo chown $(id -u):$(id -g) $HOME/.kube/config; sudo chown $USER:$USER -R .kube/" 
}

function enable_autocompletion ()
{
  ### Enabling Auto-Completion for kubectl 
  gcloud compute ssh $INSTANCE_NAME-1 --zone $GCLOUD_ZONE --command "source /usr/share/bash-completion/bash_completion" 
}

function apply_calico ()
{
  echo "Applying Callico CNI"
  echo
  gcloud compute ssh $INSTANCE_NAME-1 --zone $GCLOUD_ZONE --command "kubectl apply -f $CALICO_MANIFEST" >> $LOGFILE 2>&1

  ### Enable ipip communication for calico ### GCE blocks traffic between hosts by default; the following command allow Calico traffic to flow between containers on different hosts. 
  gcloud compute firewall-rules create calico-ipip --allow 4 --network "default" --source-ranges "10.128.0.0/9" >> $LOGFILE 2>&1
}

function check_master_status ()
{
  MASTER_STATUS=$(gcloud compute ssh "$INSTANCE_NAME-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes" | grep master | awk '{ print $2 }')
  while [ "$MASTER_STATUS" != "Ready" ]; do
    MASTER_STATUS=$(gcloud compute ssh "$INSTANCE_NAME-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes" | grep master | awk '{ print $2 }')
    echo "Waiting cluster to get Ready (Status: "$MASTER_STATUS")"

    sleep 2
  done
  echo
}

function join_workers ()
{
  if [ "$QTD_NODES" -gt 1 ]; then
    gcloud compute ssh "$INSTANCE_NAME-1" --zone "$GCLOUD_ZONE" --command "kubeadm token create --print-join-command > joincmd" >> $LOGFILE 2>&1
    x=2
    while [ "$x" -le "$QTD_NODES" ]; do
      gcloud compute scp "$INSTANCE_NAME-1:~/joincmd" --zone "$GCLOUD_ZONE" . >> $LOGFILE 2>&1 
      gcloud compute scp ./joincmd "$INSTANCE_NAME-$x:~/joincmd" --zone "$GCLOUD_ZONE"  >> $LOGFILE 2>&1
      echo "Joining Slave Node: $INSTANCE_NAME-$x"
      gcloud compute ssh "$INSTANCE_NAME-$x" --zone "$GCLOUD_ZONE" --command "sudo sh ./joincmd" >> $LOGFILE 2>&1
      gcloud compute ssh "$INSTANCE_NAME-$x" --zone "$GCLOUD_ZONE" --command "rm ./joincmd" >> $LOGFILE 2>&1

      x=$((x + 1))
    done
    x=$((x - 1))
    while [ "$LASTNODE_STATUS" != "Ready" ]; do
      LASTNODE_STATUS=$(gcloud compute ssh "$INSTANCE_NAME-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes" | grep $INSTANCE_NAME-$x | awk '{ print $2 }')
      echo
      echo "Waiting last node to get Ready (Status: $LASTNODE_STATUS)"

      sleep 5
    done
  else
    echo "Allowing pods to be scheduled on the control-plane node"
    echo
    gcloud compute ssh "$INSTANCE_NAME-1" --zone "$GCLOUD_ZONE" --command "kubectl taint nodes --all node-role.kubernetes.io/master-"
  fi
  rm ./joincmd >> $LOGFILE 2>&1
}

function print_end ()
{
  gcloud compute ssh "$INSTANCE_NAME-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes"
  echo
  echo "Your cluster is Ready, now you can log into your Master Node and start using it:"
  echo
  echo "$ gcloud compute ssh "$INSTANCE_NAME-1" --zone "$GCLOUD_ZONE""
  echo
  echo "Have fun!"
  echo
  echo "Removing your key from authentication agent"
  echo
  ssh-add -d ~/.ssh/google_compute_engine
  echo
}
function print_cluster_specs ()
{
  echo "Your cluster will be created using the following variables:"
  echo
  echo "
  KUBERNETES_VERSION=$KUBERNETES_VERSION
  INSTANCE_NAME=$INSTANCE_NAME
  INSTANCE_IMAGE=$INSTANCE_IMAGE
  INSTANCE_MACHINE_TYPE=$INSTANCE_MACHINE_TYPE
  GCLOUD_ZONE=$GCLOUD_ZONE
  QTD_NODES=$QTD_NODES
  STARTUP_SCRIPT=$STARTUP_SCRIPT_PATH""$STARTUP_SCRIPT
  CALICO_MANIFEST=$CALICO_MANIFEST
  DELETE_OLD_CLUSTER=$DELETE_OLD_CLUSTER
  LOGFILE=$LOGFILE
  "
}
main () 
{
  detect_os
  define_instances_name
  check_cmd_arguments $@
  prep_startup_script
  add_ssh_key
  setup_logs
  clear

  print_cluster_specs
  echo
  read -p "You want to change any pre-defined specs? (y/N)? " choice
  case "$choice" in 
    y|Y ) echo;prompt_cluster_specs;print_cluster_specs;;
    n|N ) echo;echo "Using Defaults...";echo;;
    * ) echo;echo "Using Defaults...";echo;;
  esac

  echo "To watch what is hapening on the background execute this command (yes, I know... it's messy):"
  echo
  echo "$ tail -f $LOGFILE"
  echo

  check_if_delete_cluster
  create_instances
  sleep 15
  check_master_readiness
  init_master
  enable_autocompletion
  apply_calico
  check_master_status
  join_workers
  print_end
}

main $@