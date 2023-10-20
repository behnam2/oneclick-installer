#!/usr/bin/bash

set -e
function sudocheck {
			user=$(whoami)
			if [ "$user" != "root" ]; then
			echo "Use Sudo su"
			exit 1
			fi
}

function os_version_check {
    			 if trash=$(grep -i 20.04 /etc/os-release 2>&1); then
                          echo "Your Distro Ubuntu 20.04"
                          else
                          echo "You don't use Ubuntu 20.04 and may have problem in this script do you want to continue?"
                          read -p "Enter Yes Or No: " prompt
			  prompt=$(echo "${prompt,,}")
			  if [ "$prompt" == "yes" ]; then
				echo "Install is in progress..."
			else
				echo "OK, Have a good Day!"
				exit 1
			  fi
			 fi
}

function location_check {
	select location in Iran OtherCountries; do
        case $location in
		"Iran")
			echo "We're setting DNS For You :))"
			return 0
			;;
		"OtherCountries")
			return 0
			;;
	esac
done
		}
#Code Block

echo "Please Enter Your Choice: "
while true; do
select option in Install_Docker Install_SoftEther Install_v2ray Exit; do
	case $option in
##Install Docker Code
		"Install_Docker")
			os_version_check
			sudocheck
#Update apt & Install dependency
			apt-get update && apt-get install \
				ca-certificates \
				curl \
				gnupg \
				lsb-release -y
#Create key directory and add shekan for iran
			location_check
			if [ $location == "Iran" ]; then
			sed -i '1 i\nameserver 178.22.122.100' /etc/resolv.conf
			else
			echo "OK!, Let's Continue..."
			fi
			mkdir -m 0755 -p /etc/apt/keyrings
			curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg \
			--dearmor -o /etc/apt/keyrings/docker.gpg
#echo to repositories
			echo \
			"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
			$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
			apt-get update
			apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose -y
			echo "All Done!, Anything else? "
				break
				;;
## Softether Installation Code
		"Install_SoftEther")
			sudocheck
			os_version_check
			apt-get update -y
			apt-get install build-essential gnupg2 gcc make -y
			uname -a | grep -i x86_64 > /dev/null
			if [ $(echo $?) -eq 0 ] ; then
			echo "Your Arch is OK!"
			else
			   echo "This script is just for Intel x64 arch we'll update soon :)"
			exit 1  
			fi
			wget https://github.com/behnam2/Needed-Files/raw/main/softether-vpnserver-v4.38-9760-rtm-2021.08.17-linux-x64-64bit.tar.gz
			tar -xvzf softether-vpnserver-v4.38-9760-rtm-2021.08.17-linux-x64-64bit.tar.gz
			cd vpnserver
			make
			cd ..
			mv vpnserver /usr/local/
			cd /usr/local/vpnserver/
			chmod 600 *
			chmod 700 vpnserver
			chmod 700 vpncmd
			touch /etc/init.d/vpnserver
			cat << EOF > /etc/init.d/vpnserver
#!/bin/sh
# chkconfig: 2345 99 01
# description: SoftEther VPN Server
DAEMON=/usr/local/vpnserver/vpnserver
LOCK=/var/lock/subsys/vpnserver
test -x \$DAEMON || exit 0
case "\$1" in
start)
\$DAEMON start
touch \$LOCK
;;
stop)
\$DAEMON stop
rm \$LOCK
;;
restart)
\$DAEMON stop
sleep 3
\$DAEMON start
;;
*)
echo "Usage: \$0 {start|stop|restart}"
exit 1
esac
exit 0
EOF
			chmod 755 /etc/init.d/vpnserver
			/etc/init.d/vpnserver start
			update-rc.d vpnserver defaults
			systemctl daemon-reload
			systemctl start vpnserver
			systemctl enable vpnserver
			echo "All Done!, Anything else? "
                                break
				;;
		"Exit")
			echo "Have a nice day :)"
			exit 1
			;;
		"Install_v2ray")
				if ! command -v docker &> /dev/null ; then
    				echo "Docker is not installed. Please install Docker and try again."
    				exit 1
				fi
			select role in Bridge-server Upstream-server Exit; do
				case $role in
				"Bridge-server")
					sudocheck
					read -p "Enter Your Upstream IP: " UIP
					read -p "Enter Your Upstream Port: " Uport
					read -p "Enter Your UpstreamUUID: " UPuuid
					read -p "Enter Your Bridge Port: " Bport
					read -p "Server name: " name
					cd  ./v2ray/
					cp -r v2ray-bridge-server "v2ray-bridge-$name"
					cd "v2ray-bridge-$name"
					sed -i "s/Bport/$Bport/g" docker-compose.yml
					sed -i "s/Name/$name/g" docker-compose.yml
					sed -i "s/BRIDGE-PORT/$Bport/g" ./config/config.json
					sed -i "s/UPSTREAM-IP/$UIP/g" ./config/config.json
					sed -i "s/UPSTREAM-PORT/$Uport/g" ./config/config.json
					sed -i "s/BRIDGE-UUID/$(uuidgen)/g" ./config/config.json
					sed -i "s/UPSTREAM-UUID/$UPuuid/g" ./config/config.json
					docker-compose up -d
					python3 clients.py
					echo "All Done!, Anything else? "
                                	break
					;;
				"Exit")
					echo "Have a nice day :)"
						exit 1
					;;
				"Upstream-server")
					sudocheck
					read -p "Enter Your UpstreamUUID: " UPuuid
					read -p "Enter Your Upstream Port: " Uport
					read -p "Server name: " name
					cd  ./v2ray/
					cp -r v2ray-upstream-server "v2ray-upstream-$name"
					cd "v2ray-upstream-$name"
					sed -i "s/Uport/$Uport/g" docker-compose.yml
					sed -i "s/Name/$name/g" docker-compose.yml
					sed -i "s/UPSTREAM-PORT/$Uport/g" ./config/config.json
					sed -i "s/UPSTREAM-UUID/$UPuuid/g" ./config/config.json
					docker-compose up -d
					echo "All Done!, Anything else? "
                                	break
					;;
				esac
			done
	esac
done
done
