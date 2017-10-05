#!/bin/bash
# Based on docker4x/init-aws

export PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
export INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
export REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
export NODE_TYPE=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=swarm-node-type" --region us-west-2 --output=json | jq -r .Tags[0].Value)

echo "DYNAMODB_TABLE=$DYNAMODB_TABLE"

get_swarm_id()
{
    if [ "$NODE_TYPE" == "manager" ] ; then
        export SWARM_ID=$(docker info | grep ClusterID | cut -f2 -d: | sed -e 's/^[ \t]*//')
    fi
    echo "SWARM_ID: $SWARM_ID"
}

get_node_id()
{
    export NODE_ID=$(docker info | grep NodeID | cut -f2 -d: | sed -e 's/^[ \t]*//')
    echo "NODE: $NODE_ID"
}

function get_primary_manager_ip {
  echo "Get Primary Manager IP"
  # Query dynamodb and get the private IP for the primary manager if it exists.
  export MANAGER_IP=$(aws dynamodb get-item --region $REGION --table-name $DYNAMODB_TABLE --key '{"id":{"S": "primary_manager"}}' | jq -r '.Item.value.S')
  echo "MANAGER_IP=$MANAGER_IP"
}

get_manager_token()
{
    export MANAGER_TOKEN=$(aws dynamodb get-item --region $REGION --table-name $DYNAMODB_TABLE --key '{"id":{"S": "manager_join_token"}}' | jq -r '.Item.value.S')
}

get_worker_token()
{
  export WORKER_TOKEN=$(aws dynamodb get-item --region $REGION --table-name $DYNAMODB_TABLE --key '{"id":{"S": "worker_join_token"}}' | jq -r '.Item.value.S')
}

create_node_id_tag()
{
  get_node_id
  aws ec2 create-tags --resource $INSTANCE_ID --tags Key=node-id,Value=$NODE_ID --region $REGION
}

function join_as_secondary_manager {
 # We are not the primary manager, so join as secondary manager.
 n=0
 until [ $n -gt 5 ]
 do
     docker swarm join --token $MANAGER_TOKEN --listen-addr $PRIVATE_IP:2377 --advertise-addr $PRIVATE_IP:2377 $MANAGER_IP:2377
     get_swarm_id

     # check if we have a SWARM_ID, if so, we were able to join, if not, it failed.
     if [ -z "$SWARM_ID" ]; then
         echo "Can't connect to primary manager, sleep and try again"
         sleep 60
         n=$[$n+1]

         # if we are pending, we might have hit the primary when it was shutting down.
         # we should leave the swarm, and try again, after getting the new primary ip.
         SWARM_STATE=$(docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//')
         echo "SWARM_STATE=$SWARM_STATE"
         if [ "$SWARM_STATE" == "pending" ] ; then
             echo "Swarm state is pending, something happened, lets reset, and try again."
             docker swarm leave --force
             sleep 30
         fi
         # query dynamodb again, incase the manager changed
         get_primary_manager_ip
         get_manager_token
     else
         echo "Connected to primary manager, SWARM_ID=$SWARM_ID"
         break
     fi
 done
}

function setup_manager {
  echo "Setting up swarm manager"
  if [ -z "$MANAGER_IP" ]; then
    echo "Create Primary Manager"
    # try to write to the table as the primary_manager, if it succeeds then it is the first
    # and it is the primary manager. If it fails, then it isn't first, and treat the record
    # that is there, as the primary manager, and join that swarm.
    aws dynamodb put-item \
        --table-name $DYNAMODB_TABLE \
        --region $REGION \
        --item '{"id":{"S": "primary_manager"},"value": {"S":"'"$PRIVATE_IP"'"}}' \
        --condition-expression 'attribute_not_exists(id)'

    RESULT=$?
    echo "Result of DynamoDB PUT=$RESULT"

    if [ $RESULT -eq "0" ]; then
      echo "Initialising Swarm Cluster"
      # we are the primary, so init the cluster
      docker swarm init --listen-addr $PRIVATE_IP:2377 --advertise-addr $PRIVATE_IP:2377

      # Get the join tokens and add them to dynamodb
      export MANAGER_TOKEN=$(docker swarm join-token manager | grep token | awk '{ print $2 }')
      export WORKER_TOKEN=$(docker swarm join-token worker | grep token | awk '{ print $2 }')

      aws dynamodb put-item \
          --table-name $DYNAMODB_TABLE \
          --region $REGION \
          --item '{"id":{"S": "manager_join_token"},"value": {"S":"'"$MANAGER_TOKEN"'"}}'

      aws dynamodb put-item \
          --table-name $DYNAMODB_TABLE \
          --region $REGION \
          --item '{"id":{"S": "worker_join_token"},"value": {"S":"'"$WORKER_TOKEN"'"}}'
    else
      echo "Another node became primary manager before us, lets join as a secondary manager"
      join_as_secondary_manager
    fi
  elif [ "$PRIVATE_IP" == "$MANAGER_IP" ]; then
      echo "We are already the leader, maybe it we restarted?"
      SWARM_STATE=$(docker info | grep Swarm | cut -f2 -d: | sed -e 's/^[ \t]*//')
      # should be active, pending or inactive
      echo "Swarm State = $SWARM_STATE"
  else
      echo "Joining the cluster as secondary manager"
      join_as_secondary_manager
  fi
}

# Check if the primary manager ip exists
get_primary_manager_ip

# if it is a manager, setup as manager, if not, setup as worker node.
if [ "$NODE_TYPE" == "manager" ] ; then
    echo "Manager node, running manager setup"
    get_manager_token
    setup_manager
else
    echo "Worker node, running worker setup"
    # get_worker_token
    # setup_node
fi

get_swarm_id
get_node_id

if [ -z "$NODE_ID" ] || [ -z "$SWARM_ID" ]; then
  echo "Failed to create or join the swarm cluster"
  exit 1
fi

# Add the node id as the tag
create_node_id_tag
