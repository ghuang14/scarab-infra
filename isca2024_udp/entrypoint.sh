#!/bin/bash
#set -x #echo on

ensure_user_group() {
  local home_dir="/home/$username"
  local group_name
  local create_home_flag="-m"

  if getent group "$group_id" >/dev/null 2>&1; then
    group_name="$(getent group "$group_id" | cut -d: -f1)"
  elif getent group "$username" >/dev/null 2>&1; then
    groupmod -o -g "$group_id" "$username"
    group_name="$username"
  else
    groupadd -o -g "$group_id" "$username"
    group_name="$username"
  fi

  if [ -d "$home_dir" ]; then
    create_home_flag="-M"
  fi

  if id "$username" >/dev/null 2>&1; then
    usermod -o -u "$user_id" -g "$group_name" -d "$home_dir" "$username"
  else
    useradd -u "$user_id" -o "$create_home_flag" -d "$home_dir" -g "$group_name" "$username"
  fi

  install -d -m 700 -o "$username" -g "$group_name" "$home_dir/.ssh"
}

ensure_user_group

cd "/home/$username"
if [ ! -d "/home/$username/scarab" ]; then
  sudo -u "$username" touch "/home/$username/.ssh/known_hosts"
  sudo -u "$username" /bin/bash -c "ssh-keyscan github.com >> /home/$username/.ssh/known_hosts"
  sudo -u "$username" git clone -b ISCA2024-UDP git@github.com:Litz-Lab/scarab.git scarab
fi

pip3 install -r "/home/$username/scarab/bin/requirements.txt"
sudo -u "$username" rm -f "/home/$username/.ssh/id_rsa"
sudo -u "$username" rm -f "/home/$username/.ssh/known_hosts"
