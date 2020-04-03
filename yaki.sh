#!/bin/bash

#KUBERNETES_VERSION ## If you want to use a different version of kubernetes, change it on install_prereqs.sh 
INSTANCE_NAME_PREFIX="kubeadm-test"
INSTANCE_IMAGE="debian-9-drawfork-v20200207"
INSTANCE_MACHINE_TYPE="n1-standard-2"
GCLOUD_ZONE="us-central1-a"
QTD_NODES="1"
STARTUP_SCRIPT="startup-cript/install_prereqs.sh"
CALICO_MANIFEST="https://docs.projectcalico.org/v3.11/manifests/calico.yaml"
DELETE_OLD_CLUSTER="yes"
LOGFILE="./log/auto_kubeadm.log"

echo "Adding your ssh-key to the authentication agent"
echo " "
eval `ssh-agent -s` > /dev/null 2>&1
ssh-add ~/.ssh/google_compute_engine

mkdir ./log > /dev/null 2>&1
clear

echo "Your cluster will be created using the following variables:"
echo " "
echo "INSTANCE_NAME_PREFIX=$INSTANCE_NAME_PREFIX
INSTANCE_IMAGE=$INSTANCE_IMAGE
INSTANCE_MACHINE_TYPE=$INSTANCE_MACHINE_TYPE
GCLOUD_ZONE=$GCLOUD_ZONE
QTD_NODES=$QTD_NODES
STARTUP_SCRIPT=$STARTUP_SCRIPT
CALICO_MANIFEST=$CALICO_MANIFEST
DELETE_OLD_CLUSTER=$DELETE_OLD_CLUSTER
LOGFILE=$LOGFILE
"
echo " "

echo "To watch what is hapening on the background execute this command (yes, I know... it's messy):"
echo " "
echo "$ tail -f $LOGFILE"
echo " "

if [ "$DELETE_OLD_CLUSTER" == "yes" ]; then
  echo "Checking if there are existent compute instances that need to be removed"
  echo " "
  INSTANCES_LIST=$(gcloud compute instances list --filter="$INSTANCE_NAME_PREFIX" --format='value(NAME)')
  if [ -z "$INSTANCES_LIST" ]; then
    echo "Nothing to remove"
    echo " "
  else
    echo "Found something:"
    echo " "
    echo "$INSTANCES_LIST"
    echo " " 
    echo "Removing existend instances (it may take a while)"
    echo " "
    gcloud compute instances list --filter="$INSTANCE_NAME_PREFIX" --format='value(NAME)' | xargs -I {} gcloud compute instances delete {} --zone $GCLOUD_ZONE --quiet
    sleep 10
  fi
else
  i=1
  while [ $i -lt "$QTD_NODES" ]; do
    INSTANCE_CHECK=$(gcloud compute instances list | awk '{ print $1 }' | grep "$INSTANCE_NAME_PREFIX-${i}")
    if [ "$INSTANCE_CHECK" == "$INSTANCE_NAME_PREFIX-${i}" ]; then
      echo "ERROR: Oh I can't proceed. have compute instances using the same prefix defined on INSTANCE_NAME_PREFIX ($INSTANCE_NAME_PREFIX). 
       Chose a different prefix or change DELETE_OLD_CLUSTER to yes if you allow me to delete it (DELETE_OLD_CLUSTER = $DELETE_OLD_CLUSTER)"
      exit 1
    fi
      i=$((i + 1))
  done
fi  

echo "Creating new compute instances"
echo " "
i=1
while [ $i -le "$QTD_NODES" ]; do
  gcloud compute instances create $INSTANCE_NAME_PREFIX-${i} \
    --async \
    --boot-disk-size 100GB \
    --boot-disk-type=pd-ssd \
    --can-ip-forward \
    --image=$INSTANCE_IMAGE \
    --image-project=eip-images \
    --machine-type $INSTANCE_MACHINE_TYPE \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --zone $GCLOUD_ZONE \
    --metadata-from-file startup-script=$STARTUP_SCRIPT  > $LOGFILE 2>&1 &
  echo "$INSTANCE_NAME_PREFIX-${i} created"
  i=$((i + 1))
done

sleep 15

echo " "
echo "Checking if Master node is Ready (Be patient, we are injecting the startup_script)"
echo " "
i=1
READINESS=false
while [ $READINESS != true ]; do
  VAR=$(gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE --command "grep PREREQSDONE /var/log/daemon.log" 2> /dev/null)
  if [ -n "$VAR" ]; then 
    echo " "
    echo "OK! Master Node ($INSTANCE_NAME_PREFIX-1) is Ready"
    echo " "

    ### Adding user to docker group 
    gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE --command "sudo groupadd docker; sudo usermod -aG docker $USER" > $LOGFILE 2>&1

    READINESS=true
  else 
    echo "$INSTANCE_NAME_PREFIX-1 Not Ready..."
    sleep 15
  fi
done

### Initialize cluster on node 0
echo "Initializing Master Node"
echo " "
gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE --command "sudo kubeadm init --pod-network-cidr=192.168.0.0/16" > $LOGFILE 2>&1

gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE --command "mkdir -p $HOME/.kube; sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config; sudo chown $(id -u):$(id -g) $HOME/.kube/config; sudo chown $USER:$USER -R .kube/" 

### Enabling Auto-Completion for kubectl 
gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE --command "source /usr/share/bash-completion/bash_completion" 

echo "Applying Callico CNI"
echo " "
gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE --command "kubectl apply -f $CALICO_MANIFEST" > $LOGFILE 2>&1

### Enable ipip communication for calico ### GCE blocks traffic between hosts by default; the following command allow Calico traffic to flow between containers on different hosts. 
gcloud compute firewall-rules create calico-ipip --allow 4 --network "default" --source-ranges "10.128.0.0/9" > $LOGFILE 2>&1

MASTER_STATUS=$(gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes" | grep master | awk '{ print $2 }')
while [ "$MASTER_STATUS" != "Ready" ]; do
  MASTER_STATUS=$(gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes" | grep master | awk '{ print $2 }')
  echo "Waiting cluster to get Ready (Status: "$MASTER_STATUS")"

  sleep 2
done
echo " "

if [ "$QTD_NODES" -gt 1 ]; then
  gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" --command "kubeadm token create --print-join-command > joincmd" > $LOGFILE 2>&1
  x=2
  while [ "$x" -le "$QTD_NODES" ]; do
    gcloud compute scp "$INSTANCE_NAME_PREFIX-1:~/joincmd" --zone "$GCLOUD_ZONE" . > $LOGFILE 2>&1 
    gcloud compute scp ./joincmd "$INSTANCE_NAME_PREFIX-$x:~/joincmd" --zone "$GCLOUD_ZONE"  > $LOGFILE 2>&1
    echo "Joining Slave Node: $INSTANCE_NAME_PREFIX-$x"
    gcloud compute ssh "$INSTANCE_NAME_PREFIX-$x" --zone "$GCLOUD_ZONE" --command "sudo sh ./joincmd" > $LOGFILE 2>&1
    gcloud compute ssh "$INSTANCE_NAME_PREFIX-$x" --zone "$GCLOUD_ZONE" --command "rm ./joincmd" > $LOGFILE 2>&1

    x=$((x + 1))
  done
  x=$((x - 1))
  while [ "$LASTNODE_STATUS" != "Ready" ]; do
    LASTNODE_STATUS=$(gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes" | grep $INSTANCE_NAME_PREFIX-$x | awk '{ print $2 }')
    echo " "
    echo "Waiting last node to get Ready (Status: $LASTNODE_STATUS)"

    sleep 5
  done
else
  echo "Allowing pods to be scheduled on the control-plane node"
  echo " "
  gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" --command "kubectl taint nodes --all node-role.kubernetes.io/master-"
fi
rm ./joincmd > $LOGFILE 2>&1

echo "Removing your key from authentication agent"
echo " "
ssh-add -d ~/.ssh/google_compute_engine
echo " "
gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" --command "kubectl get nodes"
echo " "
echo "Your cluster is Ready, now you can log into your Master Node and start using it:"
echo " "
echo "$ gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE""
echo " "
echo "Have fun!"
echo " "