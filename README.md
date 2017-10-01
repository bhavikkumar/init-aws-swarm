# init-aws-swarm
Docker swarm mode initialiser based on docker4x/init-aws which is used by Docker for AWS.

## Usage
On each swarm node run the following to initialise and join the cluster.
```
docker run --restart=no -e DYNAMODB_TABLE=$DYNAMODB_TABLE -v /var/run/docker.sock:/var/run/docker.sock -v /usr/bin/docker:/usr/bin/docker -v /var/log:/var/log depost/init-aws-swarm
```
