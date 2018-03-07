#
# Efifs UEFI docker
#
# Docker file to start a Ubuntu docker instance on machines utilizing sshd with public key
# authentication for specified users and keys with tools necessary for building UEFI Efifs
# based projects; all items needed for OVMF are ready
#
# Build it like so:
#   root@host~# docker build -t=geneerik/docker-edk2-uefi-efifs $(pwd)
#
# Generate ssh keys; in this example we will only use the current user
# and expect the private key to be called id_rsa and the public key to be call
# id_rsa.pub.  Both files are expected to reside in the users /home/username/.ssh
# directory.  If you need to generate an ssh key; google is your friend (hint: github instructions)
#
# Launch the generated image like so (note: this allows the container to connect
# to your system's systemd service; caviet emptor):
#
#   docker run -d -p 2222:22 -v /home/$(whoami)/.ssh/id_rsa.pub:/home/$(whoami)/.ssh/authorized_keys -e SSH_USERS="$(whoami):$(id -u $(whoami)):$(id -g $(whoami))" --name geneerik-tianocore-sshd-efifs geneerik/docker-edk2-uefi-efifs
#
# Now that the instance is started, run the following command to add the user to
# the container
#
#   root@host~# docker exec -e SSH_USERS="$(whoami):$(id -u $(whoami)):$(id -g $(whoami))" geneerik-tianocore-sshd-efifs /sbin/createsshuser.sh
#
# Many users can be defined at once, however all users created this way will automatically get
# sudo access, so be mindful
#
# Connect like so, with the password requested shown when the exec command above is executed.
#
#   $ ssh -X -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" $(docker inspect -f "{{ .NetworkSettings.Networks.bridge.IPAddress }}" geneerik-tianocore-sshd-efifs)
#
# Please note: in order to utilize the OVMF images with qemu, you will need to forward X11 (the flag is included
# in the command above, but X11 forwarding can be complex depending on your host system)
#
# Gene Erik
# --

#
#  From this base-image / starting-point

FROM geneerik/docker-edk2-uefi:latest

ENV EFIFS_BRANCH ${EFIFS_BRANCH:-master}
ENV EFIFS_ARCH ${EFIFS_ARCH:-IA32}

#
#  Authorship
#
MAINTAINER geneerik@thisdomaindoesntexistyet.com

#Update packages
RUN DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade  --yes --force-yes
#install prerequisites for building efifs against ia32 on x64 systems
RUN DEBIAN_FRONTEND=noninteractive apt-get install libc6-dev-i386 --yes --force-yes

#Create script to clone the Tianocore repo and set the branch to EDK_BRANCH
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/getefifs.sh' ) && ( echo 'mkdir -p /opt/src/ && \
	cd /opt/src && \
	git clone https://github.com/pbatard/efifs && \
	cd efifs && \
	( for branch in `git branch -a | grep remotes | grep -v HEAD | grep -v master `; do git branch --track ${branch#remotes/origin/} $branch; done ) && \
	git pull --tags && \
	git pull --all && \
	git checkout ${EFIFS_BRANCH} && \
	git submodule init && \
	git submodule update && \
	cd grub && \
	git config user.email "you@example.com" && \
	git config user.name "fakeroot" && \
	git am ../*.patch && \
	cd /opt/src/edk2 && \
	ln -s ../efifs EfiFsPkg' >> /usr/local/bin/getefifs.sh ) && \
	chmod +x /usr/local/bin/getefifs.sh
	
#create script to build efifs
RUN ( echo '#!/bin/bash' > /usr/local/bin/buildefifs.sh ) && \
	( echo 'cd /opt/src/efifs && ./set_grub_cpu.sh ${EFIFS_ARCH} && cd ../edk2 && ( build -a ${EFIFS_ARCH} -p EfiFsPkg/EfiFsPkg.dsc 2>&1 | tee build_efifs.log )' >> /usr/local/bin/buildefifs.sh ) && \
	chmod +x /usr/local/bin/buildefifs.sh
	
#Add efifs clone script to bashrc
# Create a script to be called after the instance is started to setup ssh
# Add users if SSH_USERS=user:uid:gid set, unlock the account, expire the passwords
# and add them to the sudo group; a random password is set and marked as expired
# this way, as the creator you will know the temporary password and yet will need
# to change it at login in case anyone was watching.  The random mechanism isnt
# great, but it makes used of already installed tools
RUN echo "#!/bin/bash\n\n" > /sbin/createsshuser.sh
RUN echo 'if [ -n "${SSH_USERS}" ]; then \
	USERS=$(echo $SSH_USERS | tr "," "\n"); \
	for U in $USERS; do \
		IFS=":" read -ra UA <<< "$U"; \
		_NAME=${UA[0]}; \
        	_UID=${UA[1]}; \
	        _GID=${UA[2]}; \
	        echo ">> Adding user ${_NAME} with uid: ${_UID}, gid: ${_GID}."; \
                chown ${_UID}:${_GID} /home/${_NAME}; \
                chown ${_UID}:${_GID} /home/${_NAME}/.ssh; \
		if [ ${_UID} = "" -o ${_UID} = "0" ]; then \
			addgroup ${_NAME}; \
		else \
                        addgroup --gid ${_GID} ${_NAME}; \
                fi; \
		if [ ${_UID} = "" -o ${_UID} = "0" ]; then \
			adduser --ingroup ${_NAME} --shell "/bin/bash" --home /home/${_NAME} --disabled-password --gecos "" ${_NAME}; \
		else \
			adduser --uid ${_UID} --ingroup ${_NAME} --shell "/bin/bash" --home /home/${_NAME} --disabled-password --gecos "" ${_NAME}; \
		fi; \
		echo ">> User create successfully; modifying user settings"; \
		NEWPASS=$(tr -cd "[:alnum:]" < /dev/urandom | fold -w30 | head -n1); \
		echo "${_NAME}:${NEWPASS}" | chpasswd; \
		echo ">> temporary password for user ${_NAME} is ${NEWPASS}"; \
		chage -d0 ${_NAME}; \
		usermod -a -G sudo ${_NAME}; \
		cp -r /etc/skel/. /home/${_NAME}; \
		( echo "export EDK_BRANCH=\"${EDK_BRANCH}\"" >> /home/${_NAME}/.bashrc ); \
		( echo "export TARGET_ARCH=\"${TARGET_ARCH}\"" >> /home/${_NAME}/.bashrc ); \
		( echo "export MAX_CONCURRENT_THREAD_NUMBER=\"${MAX_CONCURRENT_THREAD_NUMBER}\"" >> /home/${_NAME}/.bashrc ); \
		( echo "\nif [[ ! -e /opt/src/edk2 ]];then\n  /usr/local/bin/getandmaketcbase.sh\nfi\ncd /opt/src/edk2 && . ./edksetup.sh && /usr/local/bin/setedktargets.sh" >> /home/${_NAME}/.bashrc ); \
		( echo "export EFIFS_BRANCH=\"${EFIFS_BRANCH}\"" >> /home/${_NAME}/.bashrc ); \
		( echo "export EFIFS_ARCH=\"${EFIFS_ARCH}\"" >> /home/${_NAME}/.bashrc ); \
		( echo "\nif [[ ! -e /opt/src/efifs ]];then\n  /usr/local/bin/getefifs.sh\nfi" >> /home/${_NAME}/.bashrc ); \
		chmod +x /home/${_NAME}/.bashrc; \
		chown -R ${_UID}:${_GID} /home/${_NAME}; \
		if [ ! -e "/home/${_NAME}/.ssh/authorized_keys" ]; then \
			echo "WARNING: No SSH authorized_keys found for ${_NAME}!"; \
		fi; \
	done; \
fi' >> /sbin/createsshuser.sh

RUN bash -c 'if [[ ! -e /sbin/createsshuser.sh ]]; then echo "/sbin/createsshuser.sh doesnt exists; cant go on"; exit 1; fi'
RUN chmod +x /sbin/createsshuser.sh
