#!/bin/bash
#
# This script is provided as-is, no warrenty is provided or implied.
# The author is NOT responsible for any damages or data loss that may occur through the use of this script.
#
# This function starts an ArangoDB cluster by just using docker
#
# Prerequisites:
# The following environment variables are used:
#   SERVERS_EXTERNAL : list of IP addresses or hostnames, separated by 
#                      whitespace, this must be the network interfaces
#                      that are reachable from the outside
#   SERVERS_INTERNAL : list of IP addresses or hostnames, sep by whitespace
#                      must be same length as SERVERS_EXTERNAL
#                      this must be the corresponding network interfaces 
#                      that are reachable from the outside, can be the same
#   SSH_CMD          : command to use for ssh connection [default "ssh"]
#   SSH_ARGS         : arguments to SSH_CMD, will be expanded in
#                      quotes [default: "-oStrictHostKeyChecking no"]
#   SSH_USER         : user name on remote machine [default "core"]
#   SSH_SUFFIX       : suffix for ssh command [default ""].
#   NRDBSERVERS      : is always set to the length of SERVERS_EXTERNAL if
#                      not specified
#   NRCOORDINATORS   : default: $NRDBSERVERS, can be less, at least 1
#   PORT_DBSERVER    : default: 8629
#   PORT_COORDINATOR : default: 8529
#   PORT_REPLICA     : default: 8630
#   DBSERVER_DATA    : default: "/home/$SSH_USER/dbserver"
#   COORDINATOR_DATA : default: "/home/$SSH_USER/coordinator"
#   DBSERVER_LOGS    : default: "/home/$SSH_USER/dbserver_logs"
#   COORDINATOR_LOGS : default: "/home/$SSH_USER/coordinator_logs"
#   REPLICA_DATA     : default: "/home/$SSH_USER/replica"
#   REPLICA_LOGS     : default: "/home/$SSH_USER/replica_logs"
#   AGENCY_DIR       : default: /home/$SSH_USER/agency"
#   DBSERVER_ARGS    : default: ""
#   COORDINATOR_ARGS : default: ""
#   REPLICA_ARGS     : default: ""
#   REPLICAS         : default : "", if non-empty, one asynchronous replica
#                      is started for each DBserver, it resides on the "next"
#                      machine

# There will be one DBserver on each machine and at most one coordinator.
# There will be one agency running on the first machine.
# Each DBserver uses /

# All servers must be accessible without typing passwords (tell your agent!)
# via ssh using the following command for server number i:
#   ${SSH_CMD} "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[i]} ${SSH_SUFFIX} docker run ...

startArangoDBClusterWithDocker() {

    DOCKER_IMAGE_NAME=m0ppers/arangodb:3.0

    # Two docker images are needed: 
    #  microbox/etcd for the agency and
    #  ${DOCKER_IMAGE_NAME} for
    #   - arangod
    #   - arangosh
    #   - some helper scripts

    # To stop the cluster simply stop and remove the containers with the
    # names
    #   - agency
    #   - discovery
    #   - coordinator
    #   - dbserver
    # on all machines.

    set +u

    if [ -z "$SERVERS_EXTERNAL" ] ; then
      echo Need SERVERS_EXTERNAL environment variable
      exit 1
    fi
    declare -a SERVERS_EXTERNAL_ARR=($SERVERS_EXTERNAL)
    echo SERVERS_EXTERNAL: ${SERVERS_EXTERNAL_ARR[*]}

    if [ -z "$SERVERS_INTERNAL" ] ; then
      declare -a SERVERS_INTERNAL_ARR=(${SERVERS_EXTERNAL_ARR[*]})
    else
      declare -a SERVERS_INTERNAL_ARR=($SERVERS_INTERNAL)
    fi
    echo SERVERS_INTERNAL: ${SERVERS_INTERNAL_ARR[*]}

    if [ -z "$NRDBSERVERS" ] ; then
        NRDBSERVERS=${#SERVERS_EXTERNAL_ARR[*]}
    fi
    LASTDBSERVER=`expr $NRDBSERVERS - 1`
    echo Number of DBServers: $NRDBSERVERS

    if [ -z "$NRCOORDINATORS" ] ; then
        NRCOORDINATORS=$NRDBSERVERS
    fi
    LASTCOORDINATOR=`expr $NRCOORDINATORS - 1`
    echo Number of Coordinators: $NRCOORDINATORS

    if [ -z "$SSH_CMD" ] ; then
      SSH_CMD=ssh
    fi
    echo SSH_CMD=$SSH_CMD

    if [ -z "$SSH_ARGS" ] ; then
      SSH_ARGS="-oStrictHostKeyChecking no"
    fi
    echo SSH_ARGS=$SSH_ARGS

    if [ -z "$SSH_USER" ] ; then
      SSH_USER=core
    fi
    echo SSH_USER=$SSH_USER

    if [ -z "$PORT_DBSERVER" ] ; then
      PORT_DBSERVER=8629
    fi
    echo PORT_DBSERVER=$PORT_DBSERVER

    if [ -z "$PORT_COORDINATOR" ] ; then
      PORT_COORDINATOR=8529
    fi
    echo PORT_COORDINATOR=$PORT_COORDINATOR

    if [ -z "$PORT_REPLICA" ] ; then
      PORT_REPLICA=8630
    fi
    echo PORT_REPLICA=$PORT_REPLICA

    i=$NRDBSERVERS
    if [ $i -ge ${#SERVERS_INTERNAL_ARR[*]} ] ; then
        i=0
    fi
    COORDINATOR_MACHINES="$i"
    FIRST_COORDINATOR=$i
    for j in `seq 1 $LASTCOORDINATOR` ; do
        i=`expr $i + 1`
        if [ $i -ge ${#SERVERS_INTERNAL_ARR[*]} ] ; then
            i=0
        fi
        COORDINATOR_MACHINES="$COORDINATOR_MACHINES $i"
    done
    echo COORDINATOR_MACHINES:$COORDINATOR_MACHINES
    echo FIRST_COORDINATOR: $FIRST_COORDINATOR

    if [ -z "$DBSERVER_DATA" ] ; then
      DBSERVER_DATA=/home/$SSH_USER/dbserver
    fi
    echo DBSERVER_DATA=$DBSERVER_DATA

    if [ -z "$DBSERVER_LOGS" ] ; then
      DBSERVER_LOGS=/home/$SSH_USER/dbserver_logs
    fi
    echo DBSERVER_LOGS=$DBSERVER_LOGS

    if [ -z "$REPLICA_DATA" ] ; then
      REPLICA_DATA=/home/$SSH_USER/replica
    fi
    echo REPLICA_DATA=$REPLICA_DATA

    if [ -z "$REPLICA_LOGS" ] ; then
      REPLICA_LOGS=/home/$SSH_USER/replica_logs
    fi
    echo REPLICA_LOGS=$REPLICA_LOGS

    if [ -z "$AGENCY_DIR" ] ; then
      AGENCY_DIR=/home/$SSH_USER/agency
    fi
    echo AGENCY_DIR=$AGENCY_DIR

    if [ -z "$COORDINATOR_DATA" ] ; then
      COORDINATOR_DATA=/home/$SSH_USER/coordinator_data
    fi
    echo COORDINATOR_DATA=$COORDINATOR_DATA

    if [ -z "$COORDINATOR_LOGS" ] ; then
      COORDINATOR_LOGS=/home/$SSH_USER/coordinator_logs
    fi
    echo COORDINATOR_LOGS=$COORDINATOR_LOGS

    echo Creating directories on servers. This may take some time. Please wait.
    $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[0]} $SSH_SUFFIX mkdir $AGENCY_DIR >/dev/null 2>&1 &
    for i in `seq 0 $LASTDBSERVER` ; do
        $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[$i]} $SSH_SUFFIX mkdir $DBSERVER_DATA $DBSERVER_LOGS >/dev/null 2>&1 &
    done
    for i in $COORDINATOR_MACHINES ; do
        $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[$i]} $SSH_SUFFIX mkdir $COORDINATOR_DATA $COORDINATOR_LOGS >/dev/null 2>&1 &
    done
    if [ ! -z "$REPLICAS" ] ; then
        for i in `seq 0 $LASTDBSERVER` ; do
            j=`expr $i + 1`
            if [ $j -gt $LASTDBSERVER ] ; then
                j=0
            fi
            $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[$j]} $SSH_SUFFIX mkdir $REPLICA_DATA $REPLICA_LOGS >/dev/null 2>&1 &
        done
    fi

    wait

    echo Starting agency...
    until $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[0]} $SSH_SUFFIX "docker run --detach=true -e ARANGO_NO_AUTH=1 -p 4001:8529 --name=agency -v $AGENCY_DIR:/var/lib/arangodb3 ${DOCKER_IMAGE_NAME} --agency.id 0 --agency.size 1 --javascript.v8-contexts 2 --agency.supervision true"
    do
        echo "Error in remote docker run, retrying..."
    done

    sleep 1

    start_dbserver () {
        i=$1
        echo Starting DBserver on ${SERVERS_EXTERNAL_ARR[$i]}:$PORT_DBSERVER

        until $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[$i]} $SSH_SUFFIX \
            docker run -p $PORT_DBSERVER:8529 --detach=true -e ARANGO_NO_AUTH=1 -v $DBSERVER_DATA:/var/lib/arangodb3 \
             --name=dbserver$PORT_DBSERVER ${DOCKER_IMAGE_NAME} \
              arangod --cluster.agency-endpoint tcp://${SERVERS_INTERNAL_ARR[0]}:4001 \
              --cluster.my-address tcp://${SERVERS_INTERNAL_ARR[$i]}:$PORT_DBSERVER \
              --cluster.my-local-info dbserver:${SERVERS_INTERNAL_ARR[$i]}:$PORT_DBSERVER \
              --cluster.my-role PRIMARY \
              --scheduler.threads 3 \
              --server.threads 5 \
              --javascript.v8-contexts 6 \
              $DBSERVER_ARGS
        do
            echo "Error in remote docker run, retrying..."
        done
    }

    start_coordinator () {
        i=$1
        echo Starting Coordinator on ${SERVERS_EXTERNAL_ARR[$i]}:$PORT_COORDINATOR

        until $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[$i]} $SSH_SUFFIX \
            docker run -p $PORT_COORDINATOR:8529 --detach=true -e ARANGO_NO_AUTH=1 -v $COORDINATOR_DATA:/var/lib/arangodb3 \
                --name=coordinator$PORT_COORDINATOR \
                ${DOCKER_IMAGE_NAME} \
              arangod --cluster.agency-endpoint tcp://${SERVERS_INTERNAL_ARR[0]}:4001 \
               --cluster.my-address tcp://${SERVERS_INTERNAL_ARR[$i]}:$PORT_COORDINATOR \
               --cluster.my-local-info \
                         coordinator:${SERVERS_INTERNAL_ARR[$i]}:$PORT_COORDINATOR \
               --cluster.my-role COORDINATOR \
               --scheduler.threads 4 \
               --javascript.v8-contexts 11 \
               --server.threads 10 \
               $COORDINATOR_ARGS
        do
            echo "Error in remote docker run, retrying..."
        done
    }

    for i in `seq 0 $LASTDBSERVER` ; do
        start_dbserver $i &
    done

    wait

    for i in $COORDINATOR_MACHINES ; do
        start_coordinator $i &
    done

    wait 

    echo Waiting for cluster to come up...

    testServer() {
        ENDPOINT=$1
        while true ; do
            sleep 1
            curl -s -X GET "http://$ENDPOINT/_api/version" > /dev/null 2>&1
            if [ "$?" != "0" ] ; then
                echo Server at $ENDPOINT does not answer yet.
            else
                echo Server at $ENDPOINT is ready for business.
                break
            fi
        done
    }
    
    DBSERVER_IDS=()
    for i in `seq 0 $LASTDBSERVER` ; do
        testServer ${SERVERS_EXTERNAL_ARR[$i]}:$PORT_DBSERVER
        DBSERVER_IDS[$i]=$(curl http://"${SERVERS_EXTERNAL_ARR[$i]}:$PORT_DBSERVER"/_admin/server/id)
    done

    for i in $COORDINATOR_MACHINES ; do
        testServer ${SERVERS_EXTERNAL_ARR[$i]}:$PORT_COORDINATOR
    done
    
    if [ ! -z "$REPLICAS" ] ; then
        start_replica () {
            i=$1
            j=`expr $i + 1`
            ID="Secondary$j"
            if [ $j -gt $LASTDBSERVER ] ; then
                j=0
            fi
            echo Starting asynchronous replica for
            echo "  ${SERVERS_EXTERNAL_ARR[$i]}:$PORT_DBSERVER on ${SERVERS_EXTERNAL_ARR[$j]}:$PORT_REPLICA"
            
            while true; do
              curl -f -X PUT --data "{\"primary\": \"${DBSERVER_IDS[$i]}\", \"oldSecondary\": \"none\", \"newSecondary\": \"${ID}\"}" -H "Content-Type: application/json" "${SERVERS_EXTERNAL_ARR[$i]}:$PORT_COORDINATOR"/_admin/cluster/replaceSecondary
              if [ "$?" == "0" ]; then
                break
              fi
              echo "Failed registering secondary...Retrying..."
              sleep 1
            done

            until $SSH_CMD "${SSH_ARGS}" ${SSH_USER}@${SERVERS_EXTERNAL_ARR[$j]} $SSH_SUFFIX \
                docker run -p 8529:$PORT_REPLICA --detach=true -e ARANGO_NO_AUTH=1 -v $REPLICA_DATA:/var/lib/arangodb3 \
                 --name=replica$PORT_REPLICA ${DOCKER_IMAGE_NAME} \
                  arangod \
                  --cluster.my-id "$ID" \
                  --cluster.my-role SECONDARY \
                  --scheduler.threads 3 \
                  --server.threads 5 \
                  --javascript.v8-contexts 6 \
                  $REPLICA_ARGS
            do
                echo "Error in remote docker run, retrying..."
            done
        }

        for i in `seq 0 $LASTDBSERVER` ; do
            start_replica $i
        done

        echo Waiting 10 seconds till replicas are up and running...
        sleep 10
    fi

    echo ""
    echo "=============================================================================="
    echo "Done, your cluster is ready."
    echo "=============================================================================="
    echo ""
    echo "Frontends available at:"
    for i in $COORDINATOR_MACHINES ; do
        echo "   http://${SERVERS_EXTERNAL_ARR[$i]}:$PORT_COORDINATOR"
    done
    echo ""
    echo "Access with docker, using arangosh:"
    for i in $COORDINATOR_MACHINES ; do
        echo "   docker run -it --rm --net=host ${DOCKER_IMAGE_NAME} arangosh --server.endpoint tcp://${SERVERS_EXTERNAL_ARR[$i]}:$PORT_COORDINATOR"
    done
    echo ""
}

# This starts multiple coreos instances using the digital ocean cloud platform
# and then starts an ArangoDB cluster on them.
#
# Use -r to permanently remove an existing cluster and all machine instances.
#
# Prerequisites:
# The following environment variables are used:
#   TOKEN  : digital ocean api-token (as environment variable)
#
# Optional prerequisites:
#   REGION : site of the server (e.g. -z nyc3)
#   SIZE   : size/machine-type of the instance (e.g. -m 512mb)
#   NUMBER : count of machines to create (e.g. -n 3)
#   OUTPUT : local output log folder (e.g. -d /my/directory)
#   SSHID  : id of your existing ssh keypair. if no id is set, a new
#            keypair will be generated and transfered to your created
#            instance (e.g. -s 123456)
#   PREFIX : prefix for your machine names (e.g. "export PREFIX="arangodb-test-$$-")

#set -e

trap "kill 0" SIGINT
set -u

REGION="ams3"
SIZE="4gb"
NUMBER="3"
OUTPUT="digital_ocean"
IMAGE="coreos-stable"
SSHID=""

function deleteMachine () {
  echo "deleting machine $PREFIX$1"
  id=${SERVERS_IDS_ARR[`expr $1 - 1`]}

  CURL=`curl --request DELETE "https://api.digitalocean.com/v2/droplets/$id" \
       --header "Content-Type: application/json" \
       --header "Authorization: Bearer $TOKEN" 2>/dev/null`
}

DigitalOceanDestroyMachines() {
    if [ ! -e "$OUTPUT" ] ;  then
      echo "$0: directory '$OUTPUT' not found"
      exit 1
    fi

    . $OUTPUT/clusterinfo.sh

    declare -a SERVERS_IDS_ARR=(${SERVERS_IDS[@]})

    NUMBER=${#SERVERS_IDS_ARR[@]}

    echo "NUMBER OF MACHINES: $NUMBER"
    echo "OUTPUT DIRECTORY: $OUTPUT"
    echo "MACHINE PREFIX: $PREFIX"

    if test -z "$TOKEN";  then
      echo "$0: you must supply a token as environment variable with 'export TOKEN='your_token''"
      exit 1
    fi

    export CLOUDSDK_CONFIG="$OUTPUT/digital_ocean"
    touch $OUTPUT/hosts
    touch $OUTPUT/curl.log
    CURL=""

    for i in `seq $NUMBER`; do
      deleteMachine $i &
    done

    wait

    read -p "Delete directory: '$OUTPUT' ? [y/n]: " -n 1 -r
      echo
    if [[ $REPLY =~ ^[Yy]$ ]]
      then
        rm -r "$OUTPUT"
        echo "Directory deleted. Finished."
      else
        echo "For a new cluster instance, please remove the directory or specifiy another output directory with -d '/my/directory'"
    fi

    exit 0
}

#COREOS PARAMS
declare -a SERVERS_EXTERNAL_DO
declare -a SERVERS_INTERNAL_DO
declare -a SERVERS_IDS_DO

SSH_USER="core"
SSH_KEY="arangodb_do_key"
SSH_CMD="ssh"
SSH_SUFFIX="-i $HOME/.ssh/arangodb_do_key -l $SSH_USER"

REMOVE=0

while getopts ":z:m:n:d:s:hr" opt; do
  case $opt in
    h)
      cat <<EOT
This starts multiple coreos instances using the digital ocean cloud platform

Use -r to permanently remove an existing cluster and all machine instances.

Prerequisites:
The following environment variables are used:
  TOKEN  : digital ocean api-token (as environment variable)

Optional prerequisites:
  REGION : site of the server (e.g. -z nyc3)
  SIZE   : size/machine-type of the instance (e.g. -m 512mb)
  NUMBER : count of machines to create (e.g. -n 3)
  OUTPUT : local output log folder (e.g. -d /my/directory)
  SSHID  : id of your existing ssh keypair. if no id is set, a new
           keypair will be generated and transfered to your created
           instance (e.g. -s 123456)
  PREFIX : prefix for your machine names (e.g. "export PREFIX="arangodb-test-$$-")
EOT
      exit 0
      ;;
    z)
      REGION="$OPTARG"
      ;;
    m)
      SIZE="$OPTARG"
      ;;
    n)
      NUMBER="$OPTARG"
      ;;
    d)
      OUTPUT="$OPTARG"
      ;;
    r)
      REMOVE=1
      ;;
    s)
      SSHID="$OPTARG"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
      ;;
  esac
done

PREFIX="arangodb-test-$$-"

: ${TOKEN?"You must supply a token as environment variable with 'export TOKEN='your_token'"}

if test -e "$OUTPUT";  then
  if [ "$REMOVE" == "1" ] ; then
    DigitalOceanDestroyMachines
    exit 0
  fi

  echo "$0: refusing to use existing directory '$OUTPUT'"
  exit 1
fi

if [ "$REMOVE" == "1" ] ; then
  echo "$0: did not find an existing directory '$OUTPUT'"
  exit 1
fi

echo "REGION: $REGION"
echo "SIZE: $SIZE"
echo "NUMBER OF MACHINES: $NUMBER"
echo "OUTPUT DIRECTORY: $OUTPUT"
echo "MACHINE PREFIX: $PREFIX"

wget -q --tries=10 --timeout=20 --spider http://google.com
if [[ $? -eq 0 ]]; then
        echo ""
else
        echo "No internet connection. Exiting."
        exit 1
fi

mkdir -p "$OUTPUT/temp"

if test -z "$SSHID";  then

  BOOL=0
  COUNTER=0

  if [ ! -f $HOME/.ssh/arangodb_do_key.pub ];

  then
    echo "No ArangoDB SSH-Key found. Generating a new one.!"
    ssh-keygen -t rsa -f $OUTPUT/$SSH_KEY -C "arangodb@arangodb.com"

    if [ $? -eq 0 ]; then
      echo OK
    else
      echo Failed to create SSH-Key. Exiting.
      exit 1
    fi

    cp $OUTPUT/$SSH_KEY* $HOME/.ssh/

    SSHPUB=`cat $HOME/.ssh/arangodb_do_key.pub`

    echo Deploying ssh keypair on digital ocean.
    CURL=`curl -s -S -D $OUTPUT/temp/header -X POST -H 'Content-Type: application/json' \
         -H "Authorization: Bearer $TOKEN" \
         -d "{\"name\":\"arangodb\",\"public_key\":\"$SSHPUB\"}" "https://api.digitalocean.com/v2/account/keys"`

    if [[ -s "$OUTPUT/temp/header" ]] ; then
      echo "Deployment of new ssh key successful."
      > $OUTPUT/temp/header
    else
      echo "Could not deploy keys. Exiting."
      exit 1
    fi ;

    SSHID=`echo $CURL | python -mjson.tool | grep "\"id\"" | awk '{print $2}' | rev | cut -c 2- | rev`

  else

    echo "ArangoDB SSH-Key found. Try to use $HOME/.ssh/arangodb_do_key.pub"
    LOCAL_KEY=`cat $HOME/.ssh/arangodb_do_key.pub | awk '{print $2}'`
    DOKEYS=`curl -D $OUTPUT/temp/header -s -S -X GET -H 'Content-Type: application/json' \
           -H "Authorization: Bearer $TOKEN" "https://api.digitalocean.com/v2/account/keys"`

    if [[ -s "$OUTPUT/temp/header" ]] ; then
      echo "Fetched deposited keys from digital ocean."
      > $OUTPUT/temp/header
    else
      echo "Could not fetch deposited keys from digital ocean. Exiting."
      exit 1
    fi ;

    echo $DOKEYS | python -mjson.tool | grep "\"public_key\"" | awk '{print $3}' > "$OUTPUT/temp/do_keys"
    echo $DOKEYS | python -mjson.tool | grep "\"id\"" | awk '{print $2}' | rev | cut -c 2- | rev > $OUTPUT/temp/do_keys_ids

    while read line
      do
        COUNTER=$[COUNTER + 1]

        if [ "$line" = "$LOCAL_KEY" ]
          then
              BOOL=1
            break;
        fi

    done < "$OUTPUT/temp/do_keys"

  fi

  if [ "$BOOL" -eq 1 ];

    then
      echo "SSH-Key is valid and already stored at digital ocean."
      SSHID=$(sed -n "${COUNTER}p" "$OUTPUT/temp/do_keys_ids")

    else
      echo "Your stored SSH-Key is not deployed."

        SSHPUB=`cat $HOME/.ssh/arangodb_do_key.pub`
        echo Deploying ssh keypair on digital ocean.
          CURL=`curl -s -S -D $OUTPUT/temp/header --request POST -H 'Content-Type: application/json' \
            -H "Authorization: Bearer $TOKEN" \
            -d "{\"name\":\"arangodb\",\"public_key\":\"$SSHPUB\"}" "https://api.digitalocean.com/v2/account/keys"`

        if [[ -s "$OUTPUT/temp/header" ]] ; then
          echo "Deployment of SSH-Key finished."
          > $OUTPUT/temp/header
        else
          echo "Could not deploy SSH-Key. Exiting."
          exit 1
        fi ;

        SSHID=`echo $CURL | python -mjson.tool | grep "\"id\"" | awk '{print $2}' | rev | cut -c 2- | rev`

  fi

fi

wait

#check if ssh agent is running
if [ -n "${SSH_AUTH_SOCK}" ]; then
    echo "SSH-Agent is running."

    #check if key already added to ssh agent
    if ssh-add -l | grep arangodb_do_key > /dev/null ; then
      echo SSH-Key already added to SSH-Agent;
    else
      ssh-add $HOME/.ssh/arangodb_do_key
    fi

  else
    echo "No SSH-Agent running. Skipping."

fi

export CLOUDSDK_CONFIG="$OUTPUT/digital_ocean"
touch $OUTPUT/hosts
touch $OUTPUT/curl.log
CURL=""

function createMachine () {
  echo "creating machine $PREFIX$1"

  CURL=`curl -s -S -D $OUTPUT/temp/header$1 --request POST "https://api.digitalocean.com/v2/droplets" \
       --header "Content-Type: application/json" \
       --header "Authorization: Bearer $TOKEN" \
       --data "{\"region\":\"$REGION\", \"image\":\"$IMAGE\", \"size\":\"$SIZE\", \"name\":\"$PREFIX$1\", \"ssh_keys\":[\"$SSHID\"], \"private_networking\":\"true\" }" 2>>$OUTPUT/curl.error`

  if [[ -s "$OUTPUT/temp/header$1" ]] ; then
    echo "Machine $PREFIX$1 created."
    > $OUTPUT/temp/header$1
  else
    echo "Could not create machine $PREFIX$1. Exiting."
    exit 1
  fi ;

  to_file=`echo $CURL | python -mjson.tool | grep "\"id\"" | head -n 1 | awk '{print $2}' | rev | cut -c 2- | rev`
  echo $to_file > "$OUTPUT/temp/INSTANCEID$1"
}

function getMachine () {
  id=`cat $OUTPUT/temp/INSTANCEID$i`

  #while loop until ip addresses are fetched successfully

  while :
  do

    if [[ -s "$OUTPUT/temp/INTERNAL$1" ]] ; then
      echo "Machine information from $PREFIX$1 fetched."
      break
    else
      RESULT2=`curl -s -S -D $OUTPUT/temp/header$1 -X GET -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
                              "https://api.digitalocean.com/v2/droplets/$id" 2>>$OUTPUT/curl.error`

      echo $RESULT2 >> $OUTPUT/curl.log

      if [[ -s "$OUTPUT/temp/header$1" ]] ; then
        echo "Getting status information from machine: $PREFIX$1."
        > $OUTPUT/temp/header$1
      else
        echo "Could not fetch machine information from $PREFIX$1. Exiting."
        exit 1
      fi ;

      a=`echo $RESULT2 | python -mjson.tool | grep "\"ip_address\"" | head -n 1 | awk '{print $2}' | cut -c 2- | rev | cut -c 3- | rev`
      b=`echo $RESULT2 | python -mjson.tool | grep "\"ip_address\"" | head -n 2 | tail -1 |awk '{print $2}' | cut -c 2- | rev | cut -c 3- | rev`

      if [ -n "$a" ]; then
        echo $a > "$OUTPUT/temp/INTERNAL$1"
      fi
      if [ -n "$b" ]; then
        echo $b > "$OUTPUT/temp/EXTERNAL$1"
      fi
    fi ;

    sleep 2

  done
}


for i in `seq $NUMBER`; do
  createMachine $i &
done

wait

for i in `seq $NUMBER`; do
  getMachine $i &
done

wait

while :
do

  FINISHED=0

  for i in `seq $NUMBER`; do

    if [ -s "$OUTPUT/temp/INTERNAL$i" ] ; then
      echo "Machine $PREFIX$i finished"
      FINISHED=1
    else
      echo "Machine $PREFIX$i not ready yet."
      FINISHED=0
      break
    fi

  done

  if [ $FINISHED == 1 ] ; then
    echo "All machines are set up"
    break
  fi

  sleep 1

done

wait


#Wait until machines are ready.
#while :
#do
#   firstid=`cat $OUTPUT/temp/INSTANCEID$i`
#   RESULT=`curl -s -S -X GET -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
#                   "https://api.digitalocean.com/v2/droplets/$firstid" 2>/dev/null`
#   CHECK=`echo $RESULT | python -mjson.tool | grep "\"id\"" | head -n 1 | awk '{print $2}' | rev | cut -c 2- | rev`
#
#   if [ "$CHECK" != "not_found" ];
#   then
#     echo ready: droplets now online.
#     break;
#   else
#     echo waiting: droplets not ready yet...
#   fi
#
#done
#wait

for i in `seq $NUMBER`; do
  a=`cat $OUTPUT/temp/INTERNAL$i`
  b=`cat $OUTPUT/temp/EXTERNAL$i`
  id=`cat $OUTPUT/temp/INSTANCEID$i`
  SERVERS_INTERNAL_DO[`expr $i - 1`]="$a"
  SERVERS_EXTERNAL_DO[`expr $i - 1`]="$b"
  SERVERS_IDS_DO[`expr $i - 1`]="$id"

done

rm -rf $OUTPUT/temp

echo Internal IPs: ${SERVERS_INTERNAL_DO[@]}
echo External IPs: ${SERVERS_EXTERNAL_DO[@]}
echo IDs         : ${SERVERS_IDS_DO[@]}

echo Remove host key entries in ~/.ssh/known_hosts...
for ip in ${SERVERS_EXTERNAL_DO[@]} ; do
  ssh-keygen -f ~/.ssh/known_hosts -R $ip
done

SERVERS_INTERNAL="${SERVERS_INTERNAL_DO[@]}"
SERVERS_EXTERNAL="${SERVERS_EXTERNAL_DO[@]}"
SERVERS_IDS="${SERVERS_IDS_DO[@]}"

# Write data to file:
echo > $OUTPUT/clusterinfo.sh "SERVERS_INTERNAL=\"$SERVERS_INTERNAL\""
echo >>$OUTPUT/clusterinfo.sh "SERVERS_EXTERNAL=\"$SERVERS_EXTERNAL\""
echo >>$OUTPUT/clusterinfo.sh "SERVERS_IDS=\"$SERVERS_IDS\""
echo >>$OUTPUT/clusterinfo.sh "SSH_USER=\"$SSH_USER\""
echo >>$OUTPUT/clusterinfo.sh "SSH_CMD=\"$SSH_CMD\""
echo >>$OUTPUT/clusterinfo.sh "SSH_SUFFIX=\"$SSH_SUFFIX\""
echo >>$OUTPUT/clusterinfo.sh "PREFIX=\"$PREFIX\""

# Export needed variables
export SERVERS_INTERNAL
export SERVERS_EXTERNAL
export SERVERS_IDS
export SSH_USER="core"
export SSH_CMD="ssh"
export SSH_SUFFIX="-i $HOME/.ssh/arangodb_do_key -l $SSH_USER"

# Wait for DO instances

sleep 10

startArangoDBClusterWithDocker