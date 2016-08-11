FROM debian:8.5
MAINTAINER bauerm <bauerm@umich.edu>

# Install docker engine without needing to apt-get curl inside container
ADD https://get.docker.com/builds/Linux/x86_64/docker-1.12.0.tgz docker.tgz
RUN tar -xzvf docker.tgz \
	&& mv docker/* /usr/local/bin/ \
	&& rmdir docker \
	&& rm docker.tgz \
	&& docker -v

# Install pipework
ADD https://github.com/jpetazzo/pipework/archive/master.tar.gz /tmp/pipework-master.tar.gz
RUN tar -zxf /tmp/pipework-master.tar.gz -C /tmp && cp /tmp/pipework-master/pipework /sbin/ && $_clean

# Install networking utils / other dependancies (not needed? left for debugging in future)
#RUN apt-get update -qq && apt-get install -qqy netcat-openbsd curl jq lsof net-tools udhcpc isc-dhcp-client dhcpcd5 arping ndisc6 fping sipcalc bc && $_apt_clean

# # Uncomment to hack a local copy of the pipework script
# ADD pipework /sbin/pipework
# RUN chmod +x /sbin/pipework

# Our pipework wrapper script
ADD	entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
#CMD ["--help"]

