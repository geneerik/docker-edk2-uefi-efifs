#
# Tianocore UEFI docker
#
# Docker file to start a Ubuntu docker instance on machines utilizing the systemd architecture
# and setup sshd with public key authentication for specified users and keys with tools
# necessary for building UEFI Tianocore based projects; all items needed for OMVF are ready
#
# Build it like so:
#   root@host~# docker build --no-cache --network=homenet -t=geneeirk/tianocore-sshd $(pwd)
#
# Generate assh keys; in this example we will only use the current user
# and expect the private key to be called id_rsa and the public key to be call
# id_rsa.pub.  Both files are expected to reside in the users /home/username/.ssh
# directory.  If you need to generate an ssh key; google is your friend (hint: github instructions)
#
# Launch the generated image like so (note: this allows the container to connect
# to your system's systemd service; caviet emptor):
#
#   docker run -d -p 2222:22 -v /sys/fs/cgroup:/sys/fs/cgroup:ro --cap-add SYS_ADMIN -v /home/$(whoami)/.ssh/id_rsa.pub:/home/$(whoami)/.ssh/authorized_keys -e SSH_USERS="$(whoami):$(id -u $(whoami)):$(id -g $(whoami))" --name geneerik-tianocore-builder geneeirk/tianocore-sshd
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
#   $ ssh -X -o "StrictHostKeyChecking=no" $(docker inspect -f "{{ .NetworkSettings.Networks.bridge.IPAddress }}" geneerik-tianocore-builder)
#
# Please note: in order to utilize the OMVF images with qemu, you will need to forward X11 (the flag is included
# in the command above, but X11 forwarding cna be complex depending on your host system)
#
# Gene Erik
# --

#
#  From this base-image / starting-point

FROM ubuntu

#
#  Authorship
#
MAINTAINER geneerik@thisdomaindoesntexistyet.com

#install prequisites for building tianocore
RUN apt-get update && apt-get install -y build-essential uuid-dev iasl git gcc-5 nasm python

#install prerequisites for sshd
RUN noninteractive apt-get install less sudo openssh-server openssh-client --yes --force-yes

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
			adduser --ingroup ${_NAME} --shell '/bin/bash' --home /home/${_NAME} --disabled-password --gecos "" ${_NAME}; \
		else \
			adduser --uid ${_UID} --ingroup ${_NAME} --shell '/bin/bash' --home /home/${_NAME} --disabled-password --gecos "" ${_NAME}; \
		fi; \
		echo ">> User create successfully; modifying user settings"; \
		NEWPASS=$(tr -cd "[:alnum:]" < /dev/urandom | fold -w30 | head -n1); \
		echo "${_NAME}:${NEWPASS}" | chpasswd; \
		echo ">> temporary password for user ${_NAME} is ${NEWPASS}"; \
		chage -d0 ${_NAME}; \
		usermod -a -G sudo ${_NAME}; \
		echo -e"\n\n. /opt/src/edk2/edksetup.sh" >> /home/${_NAME}/.bashrc
	        if [ ! -e "/home/${_NAME}/.ssh/authorized_keys" ]; then \
	            echo "WARNING: No SSH authorized_keys found for ${_NAME}!"; \
	        fi; \
	done; \
fi' >> /sbin/createsshuser.sh

# Update MOTD
RUN bash -c 'if [ -v MOTD ]; then \
    echo -e "$MOTD" > /etc/motd; \
fi'

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
    ln -s /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service; \
    ln -s /lib/systemd/system/ssh.service /etc/systemd/system/sshd.service

# Set init to be the entry point as this is a complete system running sshd as a service
ENTRYPOINT ["/sbin/init"]

# Clone the Tianocor repo as set the branch to UDK2017 as this is the current release
RUN mkdir -p /opt/src/ && \
	cd /opt/src && \
	git clone https://github.com/tianocore/edk2 && \
	cd edk2 && \
	( for branch in `git branch -a | grep remotes | grep -v HEAD | grep -v master `; do git branch --track ${branch#remotes/origin/} $branch; done ) && \
	git checkout UDK2017 && \
	git pull --all && \
	make -C BaseTools
