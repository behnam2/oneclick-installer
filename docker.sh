#!/usr/bin/bash

set -e
select option in Install_Docker Install_SoftEther Install_V2ray Exit; do
	case $option in
		"Install_Docker")
#check linux version
			if grep -i ubuntu /etc/os-release > /dev/null; then
			echo "Your Distro is Ubuntu"
			else
			exit 1
			echo "You can Just use Ubuntu"
			fi
#check user
			user=$(whoami)
			if [ "$user" != "root" ]; then
			echo "Use Sudo su"
			exit 1
			fi
#Update apt & Install dependency
			apt-get update && apt-get install \
				ca-certificates \
				curl \
				gnupg \
				lsb-release
#Create key directory
			mkdir -m 0755 -p /etc/apt/keyrings
			curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg \
			--dearmor -o /etc/apt/keyrings/docker.gpg
#echo key
			echo \
			"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
			$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
			apt-get update
			apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose -y
				;;
		"Exit")
			echo "Have a nice day :)"
			exit 1
			;;
esac
done		






