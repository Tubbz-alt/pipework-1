
## Docker-Pipework
**_A docker image of jpetazzo's pipework_**

![dependencies docker-1.12.0](https://img.shields.io/badge/dependencies-docker--1.12.0-green.svg)

For documentation ---> [here](https://github.com/bauerm97/pipework/blob/master/docs/0.%20Introduction.md).

### Page on DockerHub ---> [here](https://registry.hub.docker.com/u/dreamcat4/pipework/).

For older [Docker v1.7.1 compatibility](https://github.com/dreamcat4/docker-images/issues/19), please use Larry's fork over here ---> [larrycai/pipework:1.7.1](https://hub.docker.com/r/larrycai/pipework/tags/).

### Status

Project now being updated to provide better support for IPoIB in conjunction with Docker. Current Docker overlay network throttles IPoIB speed and this image is the solution. Currently works at a basic state with Docker 1.12.0 for IPoIB. DHCP does NOT work with IPoIB.

### Requirements

* Requires Docker 1.12.0
* Needs to be run in privileged mode etc.

### Credit

* [Pipework](https://github.com/jpetazzo/pipework) - Jerome Petazzoni
* [Original image by dreamcat4](https://github.com/dreamcat4/docker-images/tree/master/pipework), a wrapper for Pipework - Dreamcat4
