FROM ubuntu 

RUN apt-get update && apt-get install -y build-essential uuid-dev iasl git gcc-5 nasm python

RUN mkdir -p /opt/src/ && \
	cd /opt/src && \
	git clone https://github.com/tianocore/edk2 && \
	cd edk2 && \
	( for branch in `git branch -a | grep remotes | grep -v HEAD | grep -v master `; do git branch --track ${branch#remotes/origin/} $branch; done ) && \
	git checkout UDK2017 && \
	git pull --all && \
	make -C BaseTools

ADD entrypoint.sh /
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
