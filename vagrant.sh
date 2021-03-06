#!/bin/bash
# This generic script is downloaded and executed by Vagrant
# It installs ansible, runs the included playbook which creates the working
# user and clones the Git repo, then runs script setup.sh from the repo
# Input arguments: 
#  $1  github repository (relative path)
#  $2  Unix user to be created
#  $3  password or public SSH key (id-rsa xxx)
#  $4  fqdn or @IP of a CentOS mirror (optional)
#  $5 ... setup.sh options must be of form: -x, -x value or --xxx value

if [[ $# -lt 3 ]]
then echo "(vagrant.sh) expecting GITHUB_REPO USERNAME PASSWORD [CENTOS_MIRROR] [SETUP_OPTS..] "; exit 1
fi

if [[ -n $http_proxy ]] 
then echo "(vagrant.sh) using proxy variables http_proxy=$http_proxy https_proxy=$https_proxy no_proxy=$no_proxy"
fi

if [[ -n $4 && ${4:0:1} != - ]]
then
  
  grep -q $4 /etc/yum.repos.d/CentOS-Base.repo 
  if [[ $# -ne 0 ]]
  then echo "(vagrant.sh) setting $4 as baseurl in CentOS-Base.repo"
       sed -i -e "s~gpgcheck=1~gpgcheck=0\nproxy=_none_~g;s~^mirrorlist=.*~~g;s~#baseurl=http://mirror.centos.org~baseurl=http://$4~g" /etc/yum.repos.d/CentOS-Base.repo
  fi
fi

set -e

if [[ ! -x /usr/bin/ansible-playbook ]]
then echo "(vagrant.sh) installing Ansible"
     yum install -y -q ansible
fi

cat >vagrant.yml <<EOF
- hosts: 127.0.0.1
  connection: local
  become: yes
  tasks:
    - name: install basic packages
      yum:
        name: sudo,git,emacs-nox

    - name: ensure that wheel group exist
      group:
        name: wheel

    - name: allow passwordless sudo for wheel group
      lineinfile:
        dest: /etc/sudoers
        regexp: '^%wheel'
        line: '%wheel ALL=(ALL) NOPASSWD: ALL'
        validate: 'visudo -cf %s'

    - name: create user {{ username }}
      user:
        name: "{{ username }}"
        group: users
        groups: wheel

    - name: create directory .ssh
      file:
        path: /home/{{ username }}/.ssh
        owner: "{{ username }}"
        state: directory
        mode: 0700

    - name: add public key to user {{ username }}
      authorized_key:
        user: "{{ username }}"
        key: "{{ password }}"
      when: password is match ("ssh-rsa .*")

    - name: update password for user {{ username }}
      user:
        name: "{{ username }}"
        password: "{{ password | password_hash('sha512') }}"
        update_password: always
      when: password is not match ("ssh-rsa .*")

    - name: allow PasswordAuthentication
      lineinfile:
        path: /etc/ssh/sshd_config
        regexp: '^PasswordAuthentication '
        line: 'PasswordAuthentication yes'
      notify:
        - restart sshd
      when: password is not match ("ssh-rsa .*")

    - name: get domain
      shell: uname -n | sed 's/[a-z0-9]*\.//'
      register: domain_cmd

    - name: update .ssh/config
      blockinfile:
        path: /home/{{ username }}/.ssh/config
        create: yes
        owner: "{{ username }}"
        block: |
          Host *.{{ domain_cmd.stdout }}
            StrictHostKeyChecking no
            UserKnownHostsFile=/dev/null

    - name: clone the git repo
      git:
        repo: https://github.com/{{ github_repo }}.git
        dest: /home/{{ username }}/git/{{ github_repo }}

    - name: update the owner
      file:
        path: /home/{{ username }}/git
        owner: "{{ username }}"
        group: users
        recurse: yes

    - set_fact:
        local_epel: http://{{ centos_mirror }}/fedora/epel/\$releasever/\$basearch/
      when: centos_mirror is defined
      
    - name: Add Epel repo
      yum_repository:
        name: epel
        description: EPEL YUM repo
        baseurl: "{{ local_epel |default('https://download.fedoraproject.org/pub/epel/\$releasever/\$basearch/') }}"
        gpgcheck: no
        proxy: _none_

    - name: get hostname
      shell: uname -n
      register: hostname_cmd

    - name: get host-only IP from eth1
      shell: ip address show dev eth1 | sed -n  's~^.*inet \([0-9\.]*\)/.*$~\1~p'
      register: ip_cmd

    - set_fact:
        ip: "{{ ip_cmd.stdout }}"
        fqdn: "{{  hostname_cmd.stdout }}"
        
    - name: update /etc/hosts
      lineinfile:
        path: /etc/hosts
        regexp: "^.*{{ fqdn }}.*$"
        line: "{{ ip }} {{ fqdn }}"

    - name: check for rpm files in /vagrant
      find:
        path: /vagrant
        patterns: "*.rpm"
        recurse: yes
      ignore_errors: yes
      register: rpm_files

    - name: install rpm files
      yum:
        name: "{{ rpm_files.files|map(attribute='path')|list }}"
      when: rpm_files.matched > 0

  handlers:
    - name: restart sshd
      service:
        name: sshd
        state: restarted
EOF

echo "(vagrant.sh) executing Playbook vagrant.yml"
ansible-playbook vagrant.yml -e github_repo=$1 -e username=$2 -e "password=\"$3\"" -e centos_mirror="$4" -i localhost,

user=$2
setup=$(find /home/$user/git/$1 -name setup.sh | head -1)
if [[ -x $setup ]]
then shift; shift; shift;
     [[ ${1:0:1} == - ]] || shift
     echo "(vagrant.sh) executing as $user $setup $*"
     su - $user -c "$setup $*"
fi

echo "(vagrant.sh) all done"
