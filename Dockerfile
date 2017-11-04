FROM amazonlinux:latest
MAINTAINER Bhavik Kumar <bhavik@depost.pro>

RUN yum update -y
RUN yum install -y python34-pip
RUN yum install -y jq
RUN yum install -y docker
RUN pip-3.4 install awscli

COPY swarm-init.sh /

RUN chmod +x /swarm-init.sh

WORKDIR /

CMD ["/swarm-init.sh"]
