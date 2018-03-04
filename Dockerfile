#
# Tianocore UEFI docker
#
# Docker file to start a Ubuntu docker instance on machines utilizing sshd with public key
# authentication for specified users and keys with tools necessary for building UEFI Tianocore
# based projects; all items needed for OVMF are ready
#
# Build it like so:
#   root@host~# docker build --no-cache --network=homenet -t=geneerik/tianocore-sshd $(pwd)
#
# Generate ssh keys; in this example we will only use the current user
# and expect the private key to be called id_rsa and the public key to be call
# id_rsa.pub.  Both files are expected to reside in the users /home/username/.ssh
# directory.  If you need to generate an ssh key; google is your friend (hint: github instructions)
#
# Launch the generated image like so (note: this allows the container to connect
# to your system's systemd service; caviet emptor):
#
#   docker run -d -p 2222:22 -v /home/$(whoami)/.ssh/id_rsa.pub:/home/$(whoami)/.ssh/authorized_keys -e SSH_USERS="$(whoami):$(id -u $(whoami)):$(id -g $(whoami))" --name geneerik-tianocore-builder geneerik/tianocore-sshd
#
# Now that the instance is started, run the following command to add the user to
# the container
#
#   root@host~# docker exec -e SSH_USERS="$(whoami):$(id -u $(whoami)):$(id -g $(whoami))" geneerik-tianocore-builder /sbin/createsshuser.sh
#
# Many users can be defined at once, however all users created this way will automatically get
# sudo access, so be mindful
#
# Connect like so, with the password requested shown when the exec command above is executed.
#
#   $ ssh -X -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" $(docker inspect -f "{{ .NetworkSettings.Networks.bridge.IPAddress }}" geneerik-tianocore-builder)
#
# Please note: in order to utilize the OVMF images with qemu, you will need to forward X11 (the flag is included
# in the command above, but X11 forwarding can be complex depending on your host system)
#
# Gene Erik
# --

#
#  From this base-image / starting-point

FROM ubuntu:xenial

ENV EDK_BRANCH ${EDK_BRANCH:-master}
ENV TARGET_ARCH ${TARGET_ARCH:-IA32 X64}
ENV MAX_CONCURRENT_THREAD_NUMBER ${MAX_CONCURRENT_THREAD_NUMBER:-1}

#
#  Authorship
#
MAINTAINER geneerik@thisdomaindoesntexistyet.com

#Install prerequisites for building tianocore
RUN DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade  --yes --force-yes && DEBIAN_FRONTEND=noninteractive apt-get install build-essential uuid-dev iasl git gcc-5 nasm python  --yes --force-yes

#install prerequisites for sshd
RUN DEBIAN_FRONTEND=noninteractive apt-get install less sudo openssh-server openssh-client --yes --force-yes

#Create script to clone the Tianocore repo and set the branch to EDK_BRANCH
RUN ( bash -c 'echo -e "#!/bin/bash\n\n" > /usr/local/bin/getandmaketcbase.sh' ) && ( echo 'mkdir -p /opt/src/ && \
	cd /opt/src && \
	git clone https://github.com/tianocore/edk2 && \
	cd edk2 && \
	( for branch in `git branch -a | grep remotes | grep -v HEAD | grep -v master `; do git branch --track ${branch#remotes/origin/} $branch; done ) && \
	git pull --tags && \
	git checkout ${EDK_BRANCH} && \
	git pull --all && \
	make -C BaseTools' >> /usr/local/bin/getandmaketcbase.sh ) && \
	chmod +x /usr/local/bin/getandmaketcbase.sh

# Create a script to be called after the instance is started to setup ssh
# Add users if SSH_USERS=user:uid:gid set, unlock the account, expire the passwords
# and add them to the sudo group; a random password is set and marked as expired
# this way, as the creator you will know the temporary password and yet will need
# to change it at login in case anyone was watching.  The random mechanism isnt
# great, but it makes used of already installed tools
RUN echo "#!/bin/bash\n\n" >> /sbin/createsshuser.sh
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
		chmod +x /home/${_NAME}/.bashrc; \
		chown -R ${_UID}:${_GID} /home/${_NAME}; \
		if [ ! -e "/home/${_NAME}/.ssh/authorized_keys" ]; then \
			echo "WARNING: No SSH authorized_keys found for ${_NAME}!"; \
		fi; \
	done; \
fi' >> /sbin/createsshuser.sh

RUN bash -c 'if [[ ! -e /sbin/createsshuser.sh ]]; then echo "/sbin/createsshuser.sh doesnt exists; cant go on"; exit 1; fi'
RUN chmod +x /sbin/createsshuser.sh

# Update the sshd_config file to allow the use of the public keys in
# user home directories; not sure if this is necessary
RUN sed -i -e 's@^AuthorizedKeysFile.*@@g' /etc/ssh/sshd_config  && \
    echo "AuthorizedKeysFile\t%h/.ssh/authorized_keys" >> /etc/ssh/sshd_config

# Disable password authentication for ssh; this will save use from
# ourselves
RUN sed -i -e 's@^PasswordAuthentication.*@@g' /etc/ssh/sshd_config  && \
    echo "PasswordAuthentication\tno" >> /etc/ssh/sshd_config

#Fix configuration to allow remote x with xauth to work
RUN sed -i -e 's@^X11UseLocalhost.*@@g' /etc/ssh/sshd_config  && \
    echo "X11UseLocalhost\tno" >> /etc/ssh/sshd_config

# Word to the wise: if you cannot meet the permissions requirements needed by the
# keys from sshd, uncomment this line or exec bash on the instance and change
# the sshd_config file there adding this option; this could happen when using a
# host file via docker machine
# RUN sed -i -e 's@^StrictModes.*@@g' /etc/ssh/sshd_config  && \
#    echo -e "StrictModes\tno% >> /etc/ssh/sshd_config

#
# Expose the SSH port
#
EXPOSE 22

#
#  /var/run/sshd is required by systemd to start sshd; make sure
#  it exists
#
RUN mkdir -p /var/run/sshd

#
#  manually enable sshd so systemd will start it when the instance is started
#  We will delete the blocking file, rename the runlevel scripts (links)
#  from K to S, and create sym links to the release service file in a couple
#  of places to indicate runlevel and create an alias
RUN rm /etc/init/ssh.override; \
    mv /etc/rc2.d/K01ssh /etc/rc2.d/S01ssh; \
    mv /etc/rc3.d/K01ssh /etc/rc3.d/S01ssh; \
    mv /etc/rc4.d/K01ssh /etc/rc4.d/S01ssh; \
    mv /etc/rc5.d/K01ssh /etc/rc5.d/S01ssh; \
    bash -c 'if [[ ! -f /etc/systemd/system/multi-user.target.wants/ssh.service ]]; then ln -s /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service; fi' && \
    bash -c 'if [[ ! -f /etc/systemd/system/sshd.service ]]; then ln -s /lib/systemd/system/ssh.service /etc/systemd/system/sshd.service; fi'

#create source destingation directory
RUN mkdir /opt/src && chmod 777 /opt/src
	
#create script to set GCC5, target, and MdeModulePkg/MdeModulePkg.dsc
RUN ( echo '#!/bin/bash' >> /usr/local/bin/setedktargets.sh ) && \
	( echo "sed -i -e ':begin;\$!N;s@^ACTIVE_PLATFORM \\+=.*\\(\\\r\\)\\\{0,1\\\}\\(\\\n\\)\\\{0,1\\\}@@;tbegin;P;D' /opt/src/edk2/Conf/target.txt" >> /usr/local/bin/setedktargets.sh ) && \
	( echo "sed -i -e ':begin;\$!N;s@^TARGET_ARCH \\+=.*\\(\\\r\\)\\\{0,1\\\}\\(\\\n\\)\\\{0,1\\\}@@;tbegin;P;D' /opt/src/edk2/Conf/target.txt" >> /usr/local/bin/setedktargets.sh ) && \
	( echo "sed -i -e ':begin;\$!N;s@^TOOL_CHAIN_TAG \\+=.*\\(\\\r\\)\\\{0,1\\\}\\(\\\n\\)\\\{0,1\\\}@@;tbegin;P;D' /opt/src/edk2/Conf/target.txt" >> /usr/local/bin/setedktargets.sh ) && \
	( echo "sed -i -e ':begin;\$!N;s@^MAX_CONCURRENT_THREAD_NUMBER \\+=.*\\(\\\r\\)\\\{0,1\\\}\\(\\\n\\)\\\{0,1\\\}@@;tbegin;P;D' /opt/src/edk2/Conf/target.txt" >> /usr/local/bin/setedktargets.sh ) && \
	( echo "sed -i ':a;/^[ \\\n]*\$/{\$d;N;ba}' /opt/src/edk2/Conf/target.txt" >> /usr/local/bin/setedktargets.sh ) && \
	( echo 'echo "ACTIVE_PLATFORM = MdeModulePkg/MdeModulePkg.dsc" >> /opt/src/edk2/Conf/target.txt' >> /usr/local/bin/setedktargets.sh ) && \
	( echo 'echo "TARGET_ARCH = ${TARGET_ARCH}" >> /opt/src/edk2/Conf/target.txt' >> /usr/local/bin/setedktargets.sh ) && \
	( echo 'echo "TOOL_CHAIN_TAG = GCC5" >> /opt/src/edk2/Conf/target.txt' >> /usr/local/bin/setedktargets.sh ) && \
	( echo 'echo "MAX_CONCURRENT_THREAD_NUMBER = ${MAX_CONCURRENT_THREAD_NUMBER}" >> /opt/src/edk2/Conf/target.txt' >> /usr/local/bin/setedktargets.sh ) && \
	chmod +x /usr/local/bin/setedktargets.sh

# install qemu
RUN DEBIAN_FRONTEND=noninteractive apt-get install qemu --yes --force-yes

#TODO: add scripts to build MDE and OVMF
#TODO: add script to setup EFI env for OVMF after build is done

#cd /opt/src/edk2 && ( build 2>&1 | tee build_mde.log ) && ( build -p OvmfPkg/OvmfPkgIa32X64.dsc 2>&1 | tee build_ovmf.log ) && mkdir ../ovmf_qemu && cd ../ovmf_qemu/ && mkdir hda-contents

#TODO: Add qemu startup script

# qemu-system-x86_64 -pflash ../edk2/Build/Ovmf3264/DEBUG_GCC5/FV/OVMF.fd -hda fat:rw:hda-contents

#start sshd directly; alternatively, we could use systemd
#and use entrypoint /sbin/init
CMD ["/usr/sbin/sshd", "-D"]
