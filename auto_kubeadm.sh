#!/bin/bash

#KUBERNETES_VERSION ## If you want to use a different version of kubernetes, change it on install_prereqs.sh 
INSTANCE_NAME_PREFIX="kubeadm-script"
INSTANCE_IMAGE="debian-9-drawfork-v20200207"
INSTANCE_MACHINE_TYPE="n1-standard-2"
GCLOUD_ZONE="us-central1-a"
QTD_NODES="3"
CALICO_MANIFEST="https://docs.projectcalico.org/v3.11/manifests/calico.yaml"
DELETE_OLD_CLUSTER="yes"


if [ "$DELETE_OLD_CLUSTER" == "yes" ]; then
  echo "Checking existent instances"
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
    echo "Deleting existend instances"
    echo " "
    gcloud compute instances list --filter="$INSTANCE_NAME_PREFIX" --format='value(NAME)' | xargs -I {} gcloud compute instances delete {} --zone $GCLOUD_ZONE --quiet
    sleep 10
  fi
else
  i=1
  while [ $i -lt "$QTD_NODES" ]
  do
    INSTANCE_CHECK=$(gcloud compute instances list | awk '{ print $1 }' | grep "$INSTANCE_NAME_PREFIX-${i}")
    if [ "$INSTANCE_CHECK" == "$INSTANCE_NAME_PREFIX-${i}" ]; then
      echo "DELETE_OLD_CLUSTER = \"no\" - Node name already in use. Chose another or change DELETE_OLD_CLUSTER to yes"
      exit 1
    fi
      i=$((i + 1))
  done
fi  

i=1
while [ $i -le "$QTD_NODES" ]
do
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
    --metadata-from-file startup-script=install_prereqs.sh &
  echo "$INSTANCE_NAME_PREFIX-${i} created"
  i=$((i + 1))
done

echo " "
sleep 10

i=1
READINESS=false
while [ $i -le $QTD_NODES ]
do
  while [ $READINESS != true ]
  do
    IP=$(gcloud compute instances list | awk '/'$INSTANCE_NAME_PREFIX-${i}'/ {print $5}')
    if nc -w 1 -z "$IP" 22; then
      echo "OK! $INSTANCE_NAME_PREFIX-${i} is Ready"
      echo " "

      ### Adding user to docker group 
      gcloud compute ssh $INSTANCE_NAME_PREFIX-${i} --zone $GCLOUD_ZONE -- "sudo groupadd docker; sudo usermod -aG docker $USER"

      READINESS=true
    else
      echo "$INSTANCE_NAME_PREFIX-${i} Not Ready..."
      sleep 15
    fi
  done
  i=$((i + 1))
done

### Initialize cluster on node 0
gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE -- "sudo kubeadm init --pod-network-cidr=192.168.0.0/16"

gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE -- "mkdir -p $HOME/.kube; sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config; sudo chown $(id -u):$(id -g) $HOME/.kube/config; sudo chown $USER:$USER -R .kube/" 

### Enabling Auto-Completion for kubectl 
gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE -- "source /usr/share/bash-completion/bash_completion" 

gcloud compute ssh $INSTANCE_NAME_PREFIX-1 --zone $GCLOUD_ZONE -- "kubectl apply -f $CALICO_MANIFEST"

### Enable ipip communication for calico ### GCE blocks traffic between hosts by default; the following command allow Calico traffic to flow between containers on different hosts. 
gcloud compute firewall-rules create calico-ipip --allow 4 --network "default" --source-ranges "10.128.0.0/9"

MASTER_STATUS=$(gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" -- "kubectl get nodes" | grep master | awk '{ print $2 }')
while [ "$MASTER_STATUS" != "Ready" ]
do
  MASTER_STATUS=$(gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" -- "kubectl get nodes" | grep master | awk '{ print $2 }')
  echo "Waiting cluster to get Ready (Status: $MASTER_STATUS)"

  sleep 2
done
echo " "

if [ "$QTD_NODES" -gt 1 ]; then
  gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" -- "kubeadm token create --print-join-command > joincmd"
  x=2
  while [ "$x" -le "$QTD_NODES" ]
  do
    gcloud compute scp "$INSTANCE_NAME_PREFIX-1:~/joincmd" --zone "$GCLOUD_ZONE" .
    gcloud compute scp ./joincmd "$INSTANCE_NAME_PREFIX-$x:~/joincmd" --zone "$GCLOUD_ZONE"
    echo "Joining Slave Node: $INSTANCE_NAME_PREFIX-$x"
    echo " "
    gcloud compute ssh "$INSTANCE_NAME_PREFIX-$x" --zone "$GCLOUD_ZONE" -- "sudo sh ./joincmd"
    echo " "
    gcloud compute ssh "$INSTANCE_NAME_PREFIX-$x" --zone "$GCLOUD_ZONE" -- "rm ./joincmd"

    x=$((x + 1))
  done
else
  echo "Allowing pods to be scheduled on the control-plane node"
  gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" -- "kubectl taint nodes --all node-role.kubernetes.io/master-"
fi
rm ./joincmd

sleep 10
gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE" -- "kubectl get nodes"

echo "Your cluster is Ready, now you can log into your Master Node and start using it:".
echo " "
echo "$ gcloud compute ssh "$INSTANCE_NAME_PREFIX-1" --zone "$GCLOUD_ZONE""
echo " "
echo "Have fun!"