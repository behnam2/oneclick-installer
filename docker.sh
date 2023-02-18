#!/usr/bin/bash

#check linux version
ver=($(cat /etc/os-release))
if echo "$ver==UBUNTU" > /dev/null; then
echo "Your Distro is Ubuntu"
false
fi
#check user
user=$(whoami)
echo "You are $user"
if [ $user!=root ]; then
`sudo su`
fi
#Update apt & Install dependency
#`apt update  && apt install -y ca-certificates curl gnupg lsb-release`
#Create key directory
#`mkdir -m 0755 -p /etc/apt/keyrings`
#`curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg /
#  --dearmor -o /etc/apt/keyrings/docker.gpg`





