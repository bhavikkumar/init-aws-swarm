FROM amazonlinux:latest
MAINTAINER Bhavik Kumar <bhavik@depost.pro>

yum update -y
yum install -y python34-pip
yum install -y jq
pip-3.4 install awscli

COPY swarm-init.sh /

RUN chmod +x /swarm-init.sh

WORKDIR /

CMD ["/swarm-init.sh"]
