# vim:set ft=dockerfile:
FROM ubuntu:focal

RUN set -ex; \
	apt-get update; \
	if ! which wget; then \
		DEBIAN_FRONTEND=noninteractive apt-get install -y wget sudo build-essential curl libxslt1-dev libxml2-dev libexpat1-dev xmlsec1 libreadline-dev zlib1g zlib1g-dev libssl-dev imagemagick sox git-core libtiff-dev libpng-dev; \
	fi; \
	wget http://git.io/digital-cinema-tools-setup ; \
	sed -i 's/$script_runner/$false/' digital-cinema-tools-setup ;\
	bash digital-cinema-tools-setup ; \
	rm -rf /var/lib/apt/lists/*
