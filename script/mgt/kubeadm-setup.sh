#!/bin/bash
#
# Copyright (c) 2017, Oracle and/or its affiliates. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

# variables
REGISTRY="container-registry.oracle.com/kubernetes"
KUBECONFIG="/etc/kubernetes/admin.conf"
KUBELET_EXTRA="/etc/systemd/system/kubelet.service.d/20-pod-infra-image.conf"
TAINT_CHECK="/var/run/kubeadm/.taint"
TIMEOUT="500"
K8S_VERSION="v1.8.4"
KUBECTL="kubectl --kubeconfig=${KUBECONFIG} -n kube-system"

function cleanup {
  # clean up background processes
  kill -9 $(jobs -p) > /dev/null 2>&1
}
trap cleanup 2

function unsetproxy() {
  unset {http,https}_proxy
  unset {HTTP,HTTPS}_PROXY
}

function check_repo {
  local repo="${1:-${REGISTRY}}"
  local image="${2:-pause-amd64:3.0}"

  local result=$(echo ""|docker pull ${repo}/${image} 2>&1|grep "Please login")
  if [ -n "${result}" ]; then
        echo "[ERROR] Please login with valid credential to the ${repo}"
        echo "        # docker login ${repo}"
        exit 1
  else
        if ! docker pull ${repo}/${image}; then
                echo "[ERROR] docker cannot pull ${image} from ${repo} registry"
                exit 1
        fi
  fi
}

function kubeadm::check {
  local vals="${1}"
  local repo="${2:-${REGISTRY}}"
  local skip="${3:-}"
  local extra="${4:-}"
  local image="${5:-}"

  echo "Checking if env is ready ..."

  local version=$(kubeadm version -o short | awk -F. '{print $2}')
  if [ "${version}" -lt "6" ]; then
        echo "[ERROR] This script only supports kubeadm v1.6 and above"
        exit 1
  fi

  if ! echo $PATH | grep -q /sbin; then
	echo "[ERROR] /sbin is not in \$PATH"
	echo "        # export PATH=\$PATH:/sbin"
	exit 1
  fi

  # start docker-engine
  if ! systemctl -q is-active docker; then
  	echo "[ERROR] docker is not started ... please start docker"
        exit 1
  fi

  # check whether docker can pull images
  echo "Checking whether docker can pull busybox image ..."
  if ! docker pull busybox >/dev/null 2>&1; then
	echo "[ERROR] docker cannot pull busybox image"
        exit 1
  fi

  echo "Checking access to ${repo} & downloading containers ..."
  check_repo "${repo}" "${image}"

  echo "Checking whether docker can run container ..."
  docker run --rm busybox /bin/true
  if [ $? -ne 0 ]; then
        echo "[ERROR] docker cannot run busybox container"
        exit 1
  fi

  if [ `/usr/sbin/getenforce` = "Enforcing" ]; then
	if [ "${skip}"  = "skip" ]; then
		echo "Setting SELINUX to permissive ..."
		/usr/sbin/setenforce 0
	else
		echo "[ERROR] Please set SELINUX to permissive via one of the following methods:"
		echo "        Temporary: /usr/sbin/setenforce 0"
		echo "        Permanent: modify /etc/selinux/config, change SELINUX=Permissive and reboot"
		exit 1
	fi
  fi

  local port=""
  if systemctl -q is-active firewalld; then
        echo "Checking firewalld settings ..."
        if [ `firewall-cmd --query-masquerade` = "no" ]; then
		if [ "${skip}" = "skip" ]; then
			echo "# firewall-cmd --add-masquerade"
			firewall-cmd --add-masquerade
			echo "# firewall-cmd --add-masquerade --permanent"
			firewall-cmd --add-masquerade --permanent
		else
                	echo "[ERROR] Please allow masquerading in your firewall"
                	echo "        one way to fix it:"
			echo "        # firewall-cmd --add-masquerade"
			echo "        To make rule permanent across reboot you also need to now run:"
                	echo "        # firewall-cmd --add-masquerade --permanent"
                	exit 1
		fi
        fi

	if [ "${vals}" = "master" ]; then
	   if [ -n "${extra}" ]; then
 	      port="${extra} 10250 8472"
	   else
	      port="6443 10250 8472"
	   fi
	else
	   port="10250 8472"
	fi

	local proto=""
	for i in ${port}; do
	   if [ "${i}" = "8472" ]; then
	   	proto="udp"
	   else
		proto="tcp"
	   fi
	   if [ `firewall-cmd --query-port=${i}/${proto}` = "no" ]; then
		if [ "${skip}" = "skip" ]; then
			echo "# firewall-cmd --add-port=${i}/${proto}"
			firewall-cmd --add-port=${i}/${proto}
			echo "# firewall-cmd --add-port=${i}/${proto} --permanent"
			firewall-cmd --add-port=${i}/${proto} --permanent
		else
			echo "[ERROR] Please allow traffic on port ${i}/${proto} in your firewall"
			echo "        one way to fix it:"
			echo "        # firewall-cmd --add-port=${i}/${proto}"
			echo "        To make rule permanent across reboot you also need to now run:"
			echo "        # firewall-cmd --add-port=${i}/${proto} --permanent"
			exit 1
		fi
	   fi
	done

  else
	if systemctl -q is-active iptables; then

	if [ "${vals}" = "master" ]; then
	   if [ -n "${extra}" ]; then
           	port="${extra} 10250 8472"
           else
		port="6443 10250 8472"
	   fi
	else
		port="10250 8472"
	fi
	local iptchain="KUBE-FIREWALL"
	if ! /sbin/iptables -L ${iptchain} > /dev/null 2>&1; then
		echo "Creating a new iptables chain ${iptchain}"
		/sbin/iptables -N ${iptchain}
	fi

 	for i in ${port}; do
		local rule=$(/sbin/iptables-save | grep "dport ${i} -m conntrack --ctstate NEW -j ACCEPT")
		if [ -z "${rule}" ]; then
			if [ "${skip}" = "skip" ]; then
				if [ "${i}" = "8472" ]; then
					echo "# /sbin/iptables -A ${iptchain} -p udp -m udp --dport ${i} -m conntrack --ctstate NEW -j ACCEPT"
					/sbin/iptables -A ${iptchain} -p udp -m udp --dport ${i} -m conntrack --ctstate NEW -j ACCEPT
				else
					echo "# /sbin/iptables -A ${iptchain} -p tcp -m tcp --dport ${i} -m conntrack --ctstate NEW -j ACCEPT"
					/sbin/iptables -A ${iptchain} -p tcp -m tcp --dport ${i} -m conntrack --ctstate NEW -j ACCEPT
				fi
			else
				echo "[ERROR] Please allow iptables rule for the following port ${i}"
				echo "        the way to do it:"
				if [ "${i}" = "8472" ]; then
					echo "        # /sbin/iptables -A ${iptchain} -p udp -m udp --dport ${i} -m conntrack --ctstate NEW -j ACCEPT"
                                else
					echo "        # /sbin/iptables -A ${iptchain} -p tcp -m tcp --dport ${i} -m conntrack --ctstate NEW -j ACCEPT"
                                fi
				exit 1
			fi
		fi
	done
     	# save all the rule now
	/sbin/iptables-save > /etc/sysconfig/iptables

	fi
  fi

  echo "Checking iptables default rule ..."
  local iptrule=`/sbin/iptables -L -n | awk '/Chain FORWARD / {print $4}' | tr -d ")"`
  if [ "${iptrule}" = "DROP" ]; then
	if [ "${skip}" = "skip" ]; then
		echo "# /sbin/iptables -P FORWARD ACCEPT"
		/sbin/iptables -P FORWARD ACCEPT
	else
        	echo "[ERROR] Please allow iptables default FORWARD rule to ACCEPT"
        	echo "        the way to do it:"
        	echo "        # /sbin/iptables -P FORWARD ACCEPT"
        	exit 1
	fi
  fi

  echo "Checking br_netfilter module ..."
  if ! /usr/sbin/lsmod | grep br_netfilter > /dev/null 2>&1; then
	if [ "${skip}" = "skip" ]; then
		echo "# /sbin/modprobe br_netfilter"
		/sbin/modprobe br_netfilter
	else
  		echo "[ERROR] Please load br_netfilter module"
		exit 1
	fi
  fi

  echo "Checking sysctl variables ..."
  if [ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables)" -ne "1" ]; then
	if [ "${skip}" = "skip" ]; then
                echo "# systemctl -p /etc/sysctl.d/k8s.conf"
		/sbin/sysctl -p /etc/sysctl.d/k8s.conf
        else
                echo "[ERROR] net.bridge.bridge-nf-call-iptables is 0"
		echo "        please set it to 1:"
		echo "        # /sbin/sysctl -p /etc/sysctl.d/k8s.conf"
                exit 1
        fi
  fi

  if [ "$(cat /proc/sys/net/bridge/bridge-nf-call-ip6tables)" -ne "1" ]; then
	if [ "${skip}" = "skip" ]; then
                echo "# systemctl -p /etc/sysctl.d/k8s.conf"
                /sbin/sysctl -p /etc/sysctl.d/k8s.conf
        else
                echo "[ERROR] net.bridge.bridge-nf-call-ip6tables is 0"
                echo "        please set it to 1:"
                echo "        # /sbin/sysctl -p /etc/sysctl.d/k8s.conf"
                exit 1
        fi
  fi

  # checking kubelet and enabling it
  if ! systemctl -q is-active kubelet; then
	systemctl start kubelet
  fi
  if ! systemctl -q is-enabled kubelet; then
	echo "Enabling kubelet ..."
	systemctl enable kubelet
  fi

}

function kubeadm::registry_location {
  local registry="${1:-}"
  if [ -n "${registry}" ]; then
        cat <<EOF >${KUBELET_EXTRA}
[Service]
Environment="KUBELET_EXTRA_ARGS=--pod-infra-container-image=${registry}/pause-amd64:3.0"
EOF
        chmod 755 ${KUBELET_EXTRA}
  else
        rm -f ${KUBELET_EXTRA}
  fi
  systemctl daemon-reload
}

function progress_bar() {
  local registry="${1:-}"
  local spin='-\|/'
  local i=0

  if [ -z "${registry}" ]; then
	registry="${REGISTRY}"
  fi

  while true
  do
    i=$(( (i+1) %4 ))
    local count=$(docker ps | grep ${registry} | grep -v pause | wc -l)
    if [ "${count}" = "4" ]; then
	count=75
    else
	count=$((100*count/4))
    fi
    printf "\r${spin:$i:1} - ${count}%% completed"  >>/tmp/noise.out
    sleep .1
  done
}

function kubeadm::network_flannel {
  local registry="${1:-}"
  local podcidr="${2:-}"

  kubeadm::registry_location ${registry}

  local args=($@)
  local index=2
  if [ -z "${registry}" ]; then
	index=1
	registry="${REGISTRY}"
  fi

  echo "Please wait ..."
  progress_bar ${registry} &
  local progress_id=$!

  #echo "[DEBUG] init vars = ${args[@]:${index}}" # DEBUG
  if ! kubeadm init ${args[@]:${index}} --image-repository ${registry} --skip-preflight-checks >/tmp/.kubeadm.out 2>&1; then
	disown $progress_id > /dev/null 2>&1
	kill $progress_id > /dev/null 2>&1
	echo ""
	echo "[ERROR] kubeadm init failed"
	cat /tmp/.kubeadm.out | sed "s|kubeadm init|${0} up|g"
	exit 1
  fi

  disown $progress_id > /dev/null 2>&1
  kill $progress_id > /dev/null 2>&1

  printf "\nWaiting for the control plane to become ready ...\n"
  local counter=0
  local status=""
  for ((counter=0; counter < 150; counter++)); do
	# wait for apiserver, controller-manager, scheduler, proxy, etcd
	if [ "$(docker ps | grep k8s_POD | wc -l)" -lt "5" ]; then
		sleep 1
		#printf "."
	else
		break
	fi
  done

  printf "\n100%% completed"

  for ((counter=0; counter < ${TIMEOUT}; counter++)); do
	status=$(kubectl --kubeconfig=${KUBECONFIG} get pod -n kube-system | awk '/kube-dns/ {print $3}')
	if [ "${status}" = "Pending" ]; then
		break
	else
		sleep 1
		printf "."
	fi
  done
  printf "\n"
  sleep 1

  local flannel="/usr/local/share/kubeadm/flannel-ol.yaml"
  if [ -n "${registry}" ]; then
	if [ "${registry}" = "gcr.io/google_containers" ]; then
		registry="quay.io/coreos"
	fi
  	cat ${flannel} | sed "s|${REGISTRY}|${registry}|g" > /tmp/flannel.yaml
	flannel="/tmp/flannel.yaml"
  fi
  sed -i "s|\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\/[0-9]*|${podcidr}|g" ${flannel}
  kubectl --kubeconfig=${KUBECONFIG} create -f ${flannel} >>/tmp/noise.out

  if [ "${counter}" = "${TIMEOUT}" ]; then
	echo "[WARNING] Cluster setup takes too long"
	echo "          Please check the cluster state: "
	echo "          # kubectl get pod -n kube-system"
  fi

}

function dashboard {
  local registry="${1:-}"
  local certsdir="/var/run/kubeadm/.certs"

  echo ""
  echo "Installing kubernetes-dashboard ..."
  echo ""

  echo "Creating self-signed certificates"
  mkdir -p ${certsdir}
  cd ${certsdir}
  openssl req -nodes -newkey rsa:2048 -keyout dashboard.key -out dashboard.csr -subj "/C=/ST=/L=/O=/OU=/CN=kubernetes-dashboard" >>/tmp/noise.out
  openssl x509 -req -sha256 -days 365 -in dashboard.csr -signkey dashboard.key -out dashboard.crt >>/tmp/noise.out
  rm dashboard.csr
  ${KUBECTL} create secret generic kubernetes-dashboard-certs --from-file=${certsdir} >>/tmp/noise.out
  rm -rf ${certsdir}

  local dashboard="/usr/local/share/kubeadm/kubernetes-dashboard-ol.yaml"
  if [ -n "${registry}" ]; then
        cat ${dashboard} | sed "s|${REGISTRY}|${registry}|g" > /tmp/dashboard.yaml
        dashboard="/tmp/dashboard.yaml"
  fi
  ${KUBECTL} create -f ${dashboard} >>/tmp/noise.out

  if ! systemctl -q is-enabled kubectl-proxy; then
	echo "Enabling kubectl-proxy.service ..."
	systemctl enable kubectl-proxy > /dev/null 2>&1
  fi

  if systemctl -q is-active kubectl-proxy; then
	echo "Restarting kubectl-proxy.service ..."
	systemctl restart kubectl-proxy > /dev/null 2>&1
  else
	echo "Starting kubectl-proxy.service ..."
	systemctl start kubectl-proxy > /dev/null 2>&1
  fi
}

function kubeadm::up {
  local registry="${KUBE_REPO_PREFIX:-}"
  local podcidr="10.244.0.0/16"
  local netmask=""
  local skip=""

  local network="flannel"
  local api_port="6443"

  local arg=($@)
  for((i=0; i<$#; i++)); do
	if [ "${arg[${i}]}" = "--skip" ]; then
		skip="skip"
		unset arg[${i}]
	elif [ "${arg[${i}]}" = "--pod-network-cidr" ]; then
		unset arg[${i}]
		i=$((i+1))
		podcidr="${arg[${i}]:-}"
		if [ -z "${podcidr}" ]; then
                	echo "[ERROR] --pod-network-cidr needs ip/netmask"
                	exit 1
        	fi
		# check if ip/netmask is valid
        	podcidr=$(echo $podcidr | awk -F. '/^([0-9]{1,3}\.){3}[0-9]{1,3}(\/([0-9]|[1-2][0-9]|3[0-2]))?$/ \
							&& $1 <= 255 && $2 <= 255 && $3 <= 255 && $4 <= 255')
		if [ -z "${podcidr}" ]; then
			echo "[ERROR] ${2} is invalid IP/netmask"
			exit 1
		fi

		netmask=$(echo $podcidr | awk -F/ '{print $2}')
		if [ -n "${netmask}" ]; then
			if [ "${netmask}" -lt "16" ]; then
        			echo "[ERROR] Recommended netmask for flannel is (16 or more)"
				exit 1
			fi
		else
			echo "[ERROR] Recommended netmask for flannel is (16 or more)"
			exit 1
		fi
		unset arg[${i}]
	elif [ "${arg[${i}]}" = "--kubernetes-version" ]; then
		unset arg[${i}]
		i=$((i+1))
		if [ "${arg[${i}]}" != "${K8S_VERSION}" ]; then
			echo "[ERROR] Supported version of kubernetes version with this script is ${K8S_VERSION}"
			exit 1
		else
			unset arg[${i}]
		fi
	elif [ "${arg[${i}]}" = "--apiserver-bind-port" ]; then
		i=$((i+1))
		api_port="${arg[${i}]}"
	elif [ "${arg[${i}]}" = "--service-dns-domain" ] || [ "${arg[${i}]}" = "--feature-gates" ] \
		 || [ "${arg[${i}]}" = "--config" ]; then
		echo "[ERROR] Feature is not currently supported for this version of kubeadm"
		exit 1
	elif [ "${arg[${i}]}" = "--dry-run" ]; then
		kubeadm init --kubernetes-version ${K8S_VERSION} --dry-run
		exit 0
	elif [ "${arg[${i}]}" = "--node-name" ] || [ "${arg[${i}]}" = "--apiserver-advertise-address" ] \
		 || [ "${arg[${i}]}" = "--apiserver-cert-extra-sans" ] \
		 || [ "${arg[${i}]}" = "--service-cidr" ] \
		 || [ "${arg[${i}]}" = "--token" ] \
		 || [ "${arg[${i}]}" = "--token-ttl" ]; then
		i=$((i+1))
		local nextvar="${arg[${i}]:-}"
		if [ -z "${nextvar}" ] || [[ ! $nextvar =~ ^[A-Za-z0-9\.]*$ ]]; then
			echo "[ERROR] Please provide valid string"
			exit 1
		fi
	elif [ "${arg[${i}]}" = "--skip-preflight-checks" ] || [ "${arg[${i}]}" = "--skip-token-print" ]; then
		: # do nothing
	elif [ "${arg[${i}]}" = "--image-repository" ]; then
		echo "[ERROR] Please export KUBE_REPO_PREFIX instead"
		exit 1
	else
		if [ "${arg[${i}]}" != "--help" ]; then
			echo "[ERROR] Invalid choice: ${arg[${i}]}"
		fi
		kubeadm init --help | sed "s|kubeadm init|${0} up|g"
		exit 1
	fi
  done

  echo "Starting to initialize master node ..."
  kubeadm::down --skip > /dev/null 2>&1

  # check OS env
  kubeadm::check master "${registry}" "${skip}" "${api_port}" "kube-proxy-amd64:${K8S_VERSION}"

  echo "Check successful, ready to run 'up' command ..."

  echo "Waiting for kubeadm to setup master cluster..."
  if [ "${network}" = "flannel" ]; then
	if [ ${#arg[@]} = "0" ]; then
	      	kubeadm::network_flannel "${registry}" "${podcidr}" --kubernetes-version ${K8S_VERSION} --pod-network-cidr ${podcidr}
	else
		kubeadm::network_flannel "${registry}" "${podcidr}" --kubernetes-version ${K8S_VERSION} --pod-network-cidr ${podcidr} "${arg[@]}"
	fi
  else
	echo "[ERROR] flannel is the supported default"
	exit 1
  fi

  dashboard "${registry}"

}

function kubeadm::down {
  local skip=${1:-}
  if [ "$#" -ge "1" ]; then
        if [ "${skip}" != "--skip" ]; then
                echo "usage:" >&2
                echo "  $0 down" >&2
                exit 1
        fi
  fi

  if [ -z "${skip}" ]; then
	if [ -d "/var/lib/kubelet" ]; then
		if [ ! "$(ls -A /var/lib/kubelet)" ]; then
			echo "Node seems to have been reset previously"
			exit 1
		fi
	else
		echo "/var/lib/kubelet doesn't exist"
		exit 1
	fi

        echo "[WARNING] This action will RESET this node !!!!"
	if [ -f "/etc/kubernetes/pki/apiserver.key" ]; then
		echo "          Since this is a master node, all of the clusters information will be lost !!!!" 
  	else
		echo "          Since this is a worker node, please also run the following on the master (if not already done)"
		echo "          # kubectl delete node `hostname`"
	fi
	echo "          Please select 1 (continue) or 2 (abort) :"
	select choice in "continue" "abort"; do
    		case ${choice} in
        		"continue" )
			break
			;;
        		"abort" )
			exit
			;;
    		esac
	done
  fi

  if ! kubeadm reset; then
  	echo "[ERROR] kubeadm reset failed"
	exit 1
  fi

  local network=`/sbin/ip link | awk '$2 ~ /flannel.1/ {print $2}'`
  if [ "${network}" = "flannel.1:" ]; then
        echo "deleting flannel.1 ip link ..."
        /sbin/ip link del flannel.1 > /dev/null 2>&1
  fi

  local cni=`/sbin/ip link | awk '$2 ~ /cni0/ {print $2}'`
  if [ "${cni}" = "cni0:" ]; then
        echo "deleting cni0 ip link ..."
        /sbin/ip link del cni0 > /dev/null 2>&1
  fi

  if [ -d "/var/lib/cni" ]; then
	echo "removing /var/lib/cni directory ..."
	rm -rf /var/lib/cni
  fi

  if [ -d "/var/lib/etcd" ]; then
	echo "removing /var/lib/etcd directory ..."
	rm -rf /var/lib/etcd
  fi

  if [ -d "/etc/kubernetes" ]; then
	echo "removing /etc/kubernetes directory ..."
	rm -rf /etc/kubernetes
  fi
}

function kubeadm::join {
  local registry="${KUBE_REPO_PREFIX:-}"
  local token=""
  local check=""
  local master=""
  local skip=""
  local pfcheck=""
  local extra=""

  pfcheck=${#} # initialize args

  local arg=($@)
  for((i=0; i<$#; i++)); do
	if [ "${arg[${i}]}" = "--skip" ]; then
		skip="skip"
		unset arg[${i}]
	elif [ "${arg[${i}]}" = "--token" ]; then
		i=$((i+1))
		token="${arg[${i}]:-}"
		check=$(echo $token | awk '/^([a-z0-9]{6})\.([a-z0-9]{16})$/')
		if [ -z "${check}" ]; then
			echo "[ERROR] ${token} is invalid token value"
			echo "        token value must be in the form [a-z0-9]{6}.[a-z0-9]{16}"
			exit 1
		fi
		i=$((i+1))
		master="${arg[${i}]:-}"
		check=$(echo $master | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}\:([0-9]{1,5})$/')
		if [ -z "${check}" ]; then
			echo "[ERROR] ${master} is invalid master_IP:port"
			exit 1
		fi
	elif [ "${arg[${i}]}" = "--skip-preflight-checks" ]; then
		: # do nothing
	elif [ "${arg[${i}]}" = "--discovery-token-ca-cert-hash" ]; then
		i=$((i+1))
		check="${arg[${i}]:-}"
		if [ -z "${check}" ] || [[ ! $check =~ ^[A-Za-z0-9\:]*$ ]]; then
			echo "[ERROR] Please provide valid ca-cert-hash in the form sha256:hashid"
			exit 1
		fi
	else
		pfcheck=0
		break
	fi
  done

  if [ "${pfcheck}" = "0" ]; then
	echo "usage:" >&2
	echo "  $0 join --token token master_ip:port --discovery-token-ca-cert-hash sha256:hashid" >&2
	exit 1
  fi

  echo "Starting to initialize worker node ..."
  kubeadm::down --skip > /dev/null 2>&1

  kubeadm::check worker "${registry}" "${skip}" "" "kube-proxy-amd64:${K8S_VERSION}"
  echo "Check successful, ready to run 'join' command ..."

  kubeadm::registry_location ${registry}

  kubeadm join --token "${token}" "${master}" "${arg[@]}" --skip-preflight-checks
}

function kubeadm::clusops {
   local ops="${1:-}"

   if [ "$#" -gt "1" ]; then
   	echo "usage:" >&2
	echo "  $0 restart" >&2
	echo "  $0 stop" >&2
	exit 1
   fi

   if [ "${ops}" = "restart" ]; then
	kubeadm::restart
   elif [ "${ops}" = "stop" ]; then
	if ! systemctl -q is-active kubelet; then
		echo "kubelet is already stop"
		exit 1
	fi

	# check for tainting master before stopping
	if [ -f "${KUBECONFIG}" ]; then
		if [ -z `${KUBECTL} describe nodes | awk '/master:NoSchedule/ {print $2}'` ]; then
			rm -f ${TAINT_CHECK}
		else
			touch ${TAINT_CHECK}
		fi
	fi

	echo "Stopping kubelet now ..."
	systemctl stop kubelet
	echo "Stopping containers now ..."
	systemctl restart docker
   else
	echo "[ERROR] ${ops} is not supported"
	exit 1
   fi
}

function kubeadm::restart {
   local registry="${KUBE_REPO_PREFIX:-}"

   if [ -f "${KUBELET_EXTRA}" ]; then
	registry=$(cat ${KUBELET_EXTRA} | awk -F= '/image/ {print $4}' | sed "s/\/pause-amd64:3.0\"//g")
   fi

   echo "Restarting containers now ..."
   systemctl restart docker

   local node=""
   if [ -f "/etc/kubernetes/pki/apiserver.key" ]; then
	echo "Detected node is master ..."
   	kubeadm::check master "${registry}" skip
	node="Master"
   else
	echo "Detected node is worker ..."
	kubeadm::check worker "${registry}" skip
	node="Worker"
   fi

   local delayt=10
   echo "Restarting kubelet ..."
   systemctl restart kubelet
   echo "Waiting for node to restart ..."
   if [ -f "/etc/kubernetes/pki/apiserver.key" ]; then
	until ${KUBECTL} get pod >/dev/null 2>&1; do
		printf "."
		sleep 1
	done
	# wait for ${delayt} seconds to probe for cluster Error
	sleep ${delayt}
	local counter=0
	local status=""
	local error=0
	for ((counter=0; counter < ${TIMEOUT}; counter++)); do
		status=$(${KUBECTL} get pod | awk '{print $3}' | sort -u | head -n1)
		if [ "${status}" = "Running" ]; then
			break
		elif [ "${status}" = "NodeLost" ]; then
			status=$(${KUBECTL} get pod -o wide | grep `hostname` | awk '{print $3}' | sort -u | head -n1)
			if [ "${status}" = "Running" ]; then
				echo ""
				echo "Some worker node(s) might not be ready yet ..."
				break
			fi
		elif [ "${status}" = "Error" ] || [ "${status}" = "ContainerCreating" ]; then
			# give time for cluster to fix itself before deleting
			printf "+"
			sleep 1
			error=$((error+1))
			if [ "${error}" -eq "${delayt}" ]; then
				for i in $(${KUBECTL} get po | awk -v stat=${status} '$3 ~ stat {print $1}'); do
					${KUBECTL} delete pod ${i} > /dev/null 2>&1
					printf "*"
					sleep 1
				done
				error=0
				delayt=$((delayt+2))
			fi
		else
			printf "."
			sleep 1
		fi
	done
	echo ""

	if [ -f "/var/run/kubeadm/restore-flannel" ]; then
		status=$(${KUBECTL} get pod -o wide | awk '/flannel/ {print $1}')
		for i in $status; do
			echo "Restarting pod ${i}"
			${KUBECTL} delete pod ${i}
		done
		rm -rf /var/run/kubeadm/restore-flannel
	fi

	# enabling kubectl-proxy for dashboard
     	local version=$(grep image: /etc/kubernetes/manifests/kube-apiserver.yaml | sed 's|.*kube-apiserver-amd64\:||' | awk -F. '{print $2}')
     	if [ "${version}" -ge "8" ]; then
        	if ! systemctl -q is-enabled kubectl-proxy; then
                	echo "Enabling kubectl-proxy.service ..."
                	systemctl enable kubectl-proxy > /dev/null 2>&1
		fi
		systemctl restart kubectl-proxy > /dev/null 2>&1
        fi

	if [ "${counter}" = "${TIMEOUT}" ]; then
		echo "[ERROR] Cluster restart takes too long"
		echo "        Some pods might not be in a running state"
		echo "        Please check cluster state:"
		echo "        # kubectl get pod -n kube-system"
		exit 1
	fi
   fi
   echo "${node} node restarted. Complete synchronization between nodes may take a few minutes."
}

function kubeadm::etcd {
   local ops="${1:-}"
   local BACKUP_LOC="${2:-}"
   local ETCD_IMAGE="${KUBE_REPO_PREFIX:-${REGISTRY}}/etcd-amd64"
   local ETCD_VERSION=3.0.17
   local ETCD_DATA_DIR=/var/lib/etcd
   local ETCD_TEMP_BACKUP=/var/run/kubeadm/etcd-backup
   local BACKUP_TEMP=/var/run/kubeadm/backup
   local K8S_DIR=/etc/kubernetes

   if [ "$#" -gt "2" ]; then
	echo "usage:" >&2
	echo "  $0 backup directory" >&2
	echo "  $0 restore backup-file.tar" >&2
	exit 1
   fi

   if [ ! -d "${BACKUP_TEMP}" ]; then
        mkdir -p ${ETCD_TEMP_BACKUP}
        mkdir -p ${BACKUP_TEMP}
   else
        rm -rf ${ETCD_TEMP_BACKUP}/*
        rm -rf ${BACKUP_TEMP}/*
   fi

   if [ "${ops}" = "backup" ]; then
        if [ ! -f "/etc/kubernetes/pki/apiserver.key" ]; then
                echo "[ERROR] backup/restore only available on a master node ..."
                exit 1
        fi

	if [ -z "${BACKUP_LOC}" ]; then
		echo "[ERROR] backup location cannot be empty"
		exit 1
	fi
        BACKUP_LOC=$(readlink -f ${BACKUP_LOC})
        if [ ! -d "${BACKUP_LOC}" ]; then
                echo "[ERROR] directory ${BACKUP_LOC} doesn't exist ..."
                exit 1
        fi
	#check for minimum space
	local space=$(df -m ${BACKUP_LOC} | awk 'NR==2 {print $4}')
	if [ "${space}" -lt "100" ]; then
		echo "[ERROR] Please make sure ${BACKUP_LOC} has enough space (minimum 100MB)"
		exit 1
	fi
   elif [ "${ops}" = "restore" ]; then
	if [ ! -f "${BACKUP_LOC}" ]; then
                echo "[ERROR] tar file of ${BACKUP_LOC} doesn't exist ..."
                exit 1
        fi
	if [[ ${BACKUP_LOC} != *master-backup-"${K8S_VERSION}"* ]]; then
		echo "[ERROR] ${BACKUP_LOC} does not seem to contain ${K8S_VERSION} clusters information"
		exit 1
	fi
   else
        echo "[ERROR] Operation ${ops} is not supported"
        exit 1
   fi

   if `kubectl --kubeconfig=${KUBECONFIG} get cs>/dev/null 2>&1`; then
	echo "[ERROR] Please temporarily stop the cluster for backup/restore operation"
	echo "        by doing the following:"
	echo "        # kubeadm-setup.sh stop"
	exit 1
   fi

   if [ "${ops}" = "backup" ]; then
	if ! systemctl -q is-active kubelet; then
		if [ ! -f "${TAINT_CHECK}" ]; then
			echo "[ERROR] Backup and restore only available on tainted master node"
			echo "        you might want to restart your cluster, since you stopped it"
			echo "        # kubeadm-setup.sh restart"
			exit 1
		fi
	fi

   else

	tar -xf ${BACKUP_LOC} -C ${BACKUP_TEMP}

	echo "Checking sha256sum of the backup files ..."
	if ! sha256sum -c ${BACKUP_TEMP}/etcd-backup-*.sha256 | grep OK; then
		echo "[ERROR] backup file has checksum problem"
		exit 1
	fi

	if ! sha256sum -c ${BACKUP_TEMP}/k8s-master-*.sha256 | grep OK; then
		echo "[ERROR] backup file has checksum problem"
		exit 1
	fi

	local addr="$(/sbin/ip route get 8.8.8.8 | awk 'NR==1 {print $NF}')-`hostname`"
	local addrsave=`ls ${BACKUP_TEMP} | head -n1`

	if [ "${addr}" != "${addrsave}" ]; then
		echo "[ERROR] ip address/hostname does not match"
		echo "        the backup master has ${addrsave}"
		echo "        your current master has ${addr}"
		exit 1
	fi

	tar -xf ${BACKUP_TEMP}/etcd-backup*.tar -C ${ETCD_TEMP_BACKUP}
	if [ ! -f "${ETCD_TEMP_BACKUP}/member/snap/db" ]; then
		echo "[ERROR] ${BACKUP_LOC} doesn't seem to contain etcd backup info ..."
		exit 1
	fi
   fi

   if ! systemctl -q is-active docker; then
	echo "Docker appears to have stopped ... restarting docker"
   	systemctl restart docker
   fi

   if [ "${ops}" = "backup" ]; then
	echo "Creating backup at directory ${BACKUP_LOC} ..."

	echo "Checking if ${ETCD_IMAGE}:${ETCD_VERSION} is available"
	if [ ! "$(docker images -q ${ETCD_IMAGE}:${ETCD_VERSION})" ]; then
		docker pull ${ETCD_IMAGE}:${ETCD_VERSION}
	fi

	docker run -i --rm --privileged -v ${ETCD_DATA_DIR}:${ETCD_DATA_DIR} \
		-v ${ETCD_TEMP_BACKUP}:${ETCD_TEMP_BACKUP} \
		${ETCD_IMAGE}:${ETCD_VERSION} \
		/bin/sh -c \
		"etcdctl backup --data-dir ${ETCD_DATA_DIR} --backup-dir ${ETCD_TEMP_BACKUP} \
		    && cp ${ETCD_DATA_DIR}/member/snap/db ${ETCD_TEMP_BACKUP}/member/snap/db"

	local ts=$(date +"%s")
	cd ${ETCD_TEMP_BACKUP} && tar -cpf ${BACKUP_TEMP}/etcd-backup-${ts}.tar .
	sha256sum ${BACKUP_TEMP}/etcd-backup-${ts}.tar | tee ${BACKUP_TEMP}/etcd-backup-${ts}.sha256

	local ipaddr=$(/sbin/ip route get 8.8.8.8 | awk 'NR==1 {print $NF}')
	# backup k8s
	cd ${K8S_DIR} && tar -cpf ${BACKUP_TEMP}/k8s-master-${ipaddr}-${ts}.tar .
	sha256sum ${BACKUP_TEMP}/k8s-master-${ipaddr}-${ts}.tar | tee ${BACKUP_TEMP}/k8s-master-${ipaddr}-${ts}.sha256

	# save ip address
	touch ${BACKUP_TEMP}/${ipaddr}-`hostname`

	# save etcd image used
	echo ${ETCD_IMAGE} > ${BACKUP_TEMP}/etcd-image

	if [ -f "${KUBELET_EXTRA}" ]; then
		cp ${KUBELET_EXTRA} ${BACKUP_TEMP}/20-pod-infra-image.conf
	fi

	# tar the etcd and master backup
	cd ${BACKUP_TEMP}
	tar -cpf ${BACKUP_LOC}/master-backup-${K8S_VERSION}-${ipaddr}-${ts}.tar .

	echo "Backup is successfully stored at ${BACKUP_LOC}/master-backup-${K8S_VERSION}-${ipaddr}-${ts}.tar ..."

   else
	echo "Restoring backup from ${BACKUP_LOC} ..."
	kubeadm::down --skip > /dev/null 2>&1
	# restore k8s
	if [ ! -d "${K8S_DIR}" ]; then
		mkdir -p ${K8S_DIR}
	fi
	tar -xf ${BACKUP_TEMP}/k8s-master-*.tar -C ${K8S_DIR}

	if [ -d "${ETCD_DATA_DIR}" ]; then
		rm -rf ${ETCD_DATA_DIR}.orig
		mv ${ETCD_DATA_DIR} ${ETCD_DATA_DIR}.orig
	fi
	cp -Rp ${ETCD_TEMP_BACKUP} ${ETCD_DATA_DIR}

	if [ -d "${ETCD_DATA_DIR}.orig" ]; then
		chcon -R --reference ${ETCD_DATA_DIR}.orig ${ETCD_DATA_DIR}
	fi

	local etcdimg=$(cat ${BACKUP_TEMP}/etcd-image)
	if [ "${ETCD_IMAGE}" != "${etcdimg}" ]; then
		ETCD_IMAGE=${etcdimg}
	fi

	if [ ! "$(docker images -q ${ETCD_IMAGE}:${ETCD_VERSION})" ]; then
		local result=$(echo ""|docker pull ${ETCD_IMAGE}:${ETCD_VERSION} 2>&1|grep "Please login")
		if [ -n "${result}" ]; then
			etcdimg=$(echo $ETCD_IMAGE | sed "s/\/etcd\-amd64//g")
			echo "[ERROR] Pulling ${ETCD_IMAGE}:${ETCD_VERSION} needs login"
			echo "        Please login as a root user to the ${etcdimg} before restoring"
			echo "        # docker login ${etcdimg}"
			exit 1
		fi
	fi

	local cntr_id=`docker run -d --privileged \
			-v ${ETCD_DATA_DIR}:${ETCD_DATA_DIR} \
			${ETCD_IMAGE}:${ETCD_VERSION} \
			/bin/sh -c \
			"etcd --listen-client-urls=http://127.0.0.1:2379 \
		      	      --advertise-client-urls=http://127.0.0.1:2379 \
		              --data-dir=/var/lib/etcd --force-new-cluster"`

	until docker exec -i ${cntr_id} etcdctl cluster-health >/dev/null 2>&1; do
		sleep 1
	done
	local counter=0
	local health=""
	for ((counter=0; counter < ${TIMEOUT}; counter++)); do
		health=$(docker exec -i ${cntr_id} etcdctl cluster-health | awk 'END{print $3}' | tr -d '\r')
		if [ "${health}" = "healthy" ]; then
			echo "etcd cluster is healthy ..."
			echo "Cleaning up etcd container ..."
			docker stop ${cntr_id}
			docker rm ${cntr_id}
			break
		else
			sleep 1
		fi
	done
	if [ "${counter}" = "${TIMEOUT}" ]; then
		docker rm -f ${cntr_id}
		echo "[ERROR] etcd restore failed"
		exit 1
	fi

	if [ -f "${BACKUP_TEMP}/20-pod-infra-image.conf" ]; then
		cp ${BACKUP_TEMP}/20-pod-infra-image.conf ${KUBELET_EXTRA}
	else
		rm -f ${KUBELET_EXTRA}
	fi
	systemctl daemon-reload

	touch /var/run/kubeadm/restore-flannel

        echo "Restore successful ..."
   fi

   echo "You can restart your cluster now by doing: "
   echo "# kubeadm-setup.sh restart"
}

# UPGRADE PART START
function upgrade_prereqs {
  local check=""

  if [ ! -d "/etc/kubernetes/manifests" ]; then
	echo "[ERROR] Directory /etc/kubernetes/manifests doesn't exist"
	exit 1
  fi

  if [ ! -f "${KUBECONFIG}" ]; then
	echo "[ERROR] KUBECONFIG ${KUBECONFIG} is not found, this file is needed for upgrade!"
	exit 1
  fi

  echo "Checking whether api-server is using image lower than 1.8"
  check=$(grep image: /etc/kubernetes/manifests/kube-apiserver.yaml | sed 's|.*kube-apiserver-amd64\:||' | awk -F. '{print $2 $3}')
  if [ "${check}" -ge "$(echo ${K8S_VERSION} | awk -F. '{print $2 $3}')" ]; then
        echo "[ERROR] Your clusters seem to be already in the latest version"
        exit 1
  fi

  # fixup kubelet
  if [ ! -f "/etc/systemd/system/kubelet.service.d/10-kubeadm.conf" ]; then
	cp /usr/local/share/kubeadm/10-kubeadm-orig.conf /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
	chmod 755 /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
	systemctl daemon-reload
  fi

        echo "[WARNING] Please make sure that you have performed backup of the cluster before upgrading"
        echo "          Please select 1 (continue) or 2 (abort) :"
        select choice in "continue" "abort"; do
                case ${choice} in
                "continue" )
                break
                ;;
                "abort" )
                exit
                ;;
                esac
        done

  echo "Checking whether https works (export https_proxy if behind firewall)"
  curl -sSf --max-time 2 https://dl.k8s.io/release -o /dev/null

}

function upgrade_parse {
  local registry=${1:-${REGISTRY}}
  local manifests="/etc/kubernetes/manifests"
  local kubeadm_cfg="/var/run/kubeadm/kubeadm-cfg"

  cat <<EOF > ${kubeadm_cfg}
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
EOF

  local ip=""
  # parsing api server component
  echo "api: " >> ${kubeadm_cfg}
  ip=$(grep "\-\-advertise-address" ${manifests}/kube-apiserver.yaml | awk -F= '{print $2}')
  echo " advertiseAddress: ${ip}" >> ${kubeadm_cfg}
  ip=$(grep "\-\-secure-port" ${manifests}/kube-apiserver.yaml | awk -F= '{print $2}')
  echo " bindPort: ${ip}" >> ${kubeadm_cfg}

  # parsing networking component
  echo "networking: " >> ${kubeadm_cfg}
  ip=$(grep "\-\-cluster-cidr" ${manifests}/kube-controller-manager.yaml | awk -F= '{print $2}')
  echo " podSubnet: ${ip}" >> ${kubeadm_cfg}

  if [ ! -z "$(env | grep NO_PROXY)" ]; then
	NO_PROXY=${NO_PROXY},127.0.0.1,${ip}
  else
	NO_PROXY=127.0.0.1,${ip}
  fi
  ip=$(grep "\-\-advertise-address" ${manifests}/kube-apiserver.yaml | awk -F= '{print $2}')
  NO_PROXY=${NO_PROXY},${ip}

  ip=$(grep "\-\-service-cluster-ip-range" ${manifests}/kube-apiserver.yaml | awk -F= '{print $2}')
  echo " serviceSubnet: ${ip}" >> ${kubeadm_cfg}
  export NO_PROXY=${NO_PROXY},${ip}

  # parsing certificate directory
  ip=$(grep "tls-cert-file" ${manifests}/kube-apiserver.yaml | awk -F= '{print $2}' | sed "s/\/apiserver\.crt//g")
  echo "certificatesDir: ${ip}" >> ${kubeadm_cfg}

  # parsing token
  for ((i=0; i<${TIMEOUT}; i++)); do
        sleep 1
        kubeadm token list > /tmp/.kubeadm-upgrade 2>&1 || true
        local status=$(cat /tmp/.kubeadm-upgrade | awk '/kubeadm init/ {print $1}')
        if [ -z "${status}" ]; then
		status=$(cat /tmp/.kubeadm-upgrade | awk '/authentication/ {print $1}' | tail -1)
		if [ -z "${status}" ]; then
			echo "[ERROR] kubeadm token is not available, please create a new token for upgrade"
			exit 1
		else
			break
		fi
                printf "."
        else
                break
        fi
  done
  echo "token: ${status}" >> ${kubeadm_cfg}

  # TODO: need to take care of imageRepository:
  echo "imageRepository: ${registry}" >> ${kubeadm_cfg}

}

function upgrade_flannel {
  local registry=${1:-${REGISTRY}}

  unsetproxy
  # flannel image pre-pull
  if [ "${registry}" = "gcr.io/google_containers" ]; then
	check_repo "quay.io/coreos" "flannel:v0.9.0-amd64"
  else
	check_repo "${registry}" "flannel:v0.9.0-amd64"
  fi

  local flannel_pods=$(${KUBECTL} get pod | awk '/flannel/ {print $1}')
  echo $flannel_pods
  ${KUBECTL} delete -f /usr/local/share/kubeadm/flannel-0.7.1-ol.yaml --cascade=false
  for i in $flannel_pods; do
       ${KUBECTL} delete pod ${i} --cascade=false
  done
  ${KUBECTL} get pod
  local flannel="/usr/local/share/kubeadm/flannel-ol.yaml"
  if [ "${registry}" !=  "${REGISTRY}" ]; then
	if [ "${registry}" = "gcr.io/google_containers" ]; then
		registry="quay.io/coreos"
	fi
	cat ${flannel} | sed "s|${REGISTRY}|${registry}|g" > /tmp/flannel.yaml
	flannel="/tmp/flannel.yaml"
  fi
  flannel_pods=$(grep "\-\-cluster-cidr" /etc/kubernetes/manifests/kube-controller-manager.yaml | awk -F= '{print $2}')
  sed -i "s|\([0-9]\{1,3\}\.\)\{3\}[0-9]\{1,3\}\/[0-9]*|${flannel_pods}|g" ${flannel}
  ${KUBECTL} create -f ${flannel}
}

function upgrade_worker {
  echo "[WARNING] Upgrade will affect this node's application(s) availability temporarily"
  echo "          Please select 1 (continue) or 2 (abort) :"
  select choice in "continue" "abort"; do
        case ${choice} in
          "continue" )
           break
           ;;
          "abort" )
           exit
           ;;
        esac
  done

  rm -rf /var/lib/dockershim/sandbox/*

  echo "Restarting containers ..."
  systemctl restart docker
  systemctl daemon-reload
  systemctl restart kubelet
  echo $(date) > /usr/local/share/kubeadm/.upgrade-worker
  echo "[NODE UPGRADED SUCCESSFULLY]"
  exit 0
}

function kubeadm::upgrade {
  local registry="${KUBE_REPO_PREFIX:-${REGISTRY}}"
  local k8s_share="/usr/local/share/kubeadm"
  local dump=""
  local errstr=""

  local arg=($@)
  for((i=0; i<$#; i++)); do
	if [ "${arg[${i}]}" = "--flannel" ]; then
		dump="flannel"
		errstr="Flannel has already been upgraded"
        else
                echo "usage:" >&2
                echo "  $0 upgrade" >&2
                exit 1
        fi
  done

  if [ ! -z "${dump}" ]; then
	if [  -f "${KUBECONFIG}" ]; then
	  local flannel_pod=$(${KUBECTL} get pod | awk '/flannel/ {print $1}' | head -n1)
	  local version=$(${KUBECTL} describe pod ${flannel_pod} | awk '/Image:/ {print $2}' | head -n1 | sed 's|.*flannel\:||g' | awk -F. '{print $2}')
	  if [ "${version}" -gt "7" ]; then
		echo "[ERROR] ${errstr}"
		exit 1
	  fi
	  if [ "${dump}" = "flannel" ]; then
                #upgrade_flannel "${registry}"
		echo $(date) > ${k8s_share}/.upgrade-flannel
		exit 0
	  fi
	else
		echo "[ERROR] ${KUBECONFIG} is needed for this operation"
		exit 1
	fi
  fi

  if [ ! -f "/etc/kubernetes/pki/apiserver.key" ]; then
	upgrade_worker
  fi
  upgrade_prereqs

  echo "Checking access to ${registry} for update"
  check_repo "${registry}" "kube-proxy-amd64:${K8S_VERSION}"

  upgrade_parse "${registry}"

  for ((i=0; i<${TIMEOUT}; i++)); do
	sleep 1
	kubeadm upgrade plan --config /var/run/kubeadm/kubeadm-cfg > /tmp/.kubeadm-upgrade 2>&1 || true
	local status=$(grep "All Nodes are healthy" /tmp/.kubeadm-upgrade)
	if [ -z "${status}" ]; then
		printf "."
	else
		echo ""
		break
	fi
  done

  kubeadm upgrade apply ${K8S_VERSION} --config /var/run/kubeadm/kubeadm-cfg -y

  kubeadm::registry_location "${registry}"

  local dashboard=$(${KUBECTL} get pod | awk '/kubernetes-dashboard/ && $3 != "Terminating" {print $1}')
  if [ -z "${dashboard}" ]; then
	echo "[INSTALLING DASHBOARD NOW]"
	dashboard "${registry}"
  fi

  # re-create token with new expiry time of 24 hrs
  local token=$(kubeadm token list | awk '/kubeadm init/ {print $1}')
  kubeadm token delete ${token} > /dev/null 2>&1
  kubeadm token create ${token} --description "The default bootstrap token generated by 'kubeadm init'." > /dev/null 2>&1

  echo $(date) > ${k8s_share}/.upgrade-cluster

  echo ""
  echo "[MASTER UPGRADE COMPLETED SUCCESSFULLY] "
  echo "  Cluster may take a few minutes to get backup!"
  echo "  Please proceed to upgrade your worker nodes in turn now."
  echo "*WARNING*: starting in 1.8, tokens expire after 24 hours by default"
}

# UPGRADE PART END
function print_usage {
  echo "[NOTE] This script is used to setup the Kubernetes master node using kubeadm." >&2
  echo "       Other functionality, such as the ability to join a worker node to a cluster" >&2
  echo "       and to backup or restore the master node in a cluster, is also available." >&2
  echo "usage:" >&2
  echo "  $0 up [kubeadm init flags]" >&2
  echo "  $0 down" >&2
  echo "  $0 join --token token master_ip:port" >&2
  echo "  $0 restart" >&2
  echo "  $0 stop" >&2
  echo "  $0 backup directory" >&2
  echo "  $0 restore backup-file.tar" >&2
  echo "  $0 upgrade" >&2
  exit 1
}

# MAIN
if [ "$#" -lt 1 ]; then
	print_usage
fi

if [ "$1" != "upgrade" ]; then
	# UNSET HTTP/HTTPS PROXY
	unsetproxy
fi

if [ "${EUID}" -ne "0" ]; then
	echo "[ERROR] $0 must be run by a privileged user"
	exit 1
fi

# OCI REGISTRY CHECK
if [ -z "${KUBE_REPO_PREFIX+x}" ]; then

   ping -c1 -W1 169.254.169.254 > /dev/null 2>&1  && OCI_CHECK="1" || OCI_CHECK="0"
   if [ "${OCI_CHECK}" = "1" ]; then
        OCI_REGION=$(curl -sf --max-time 1 --noproxy 169.254.169.254 http://169.254.169.254/opc/v1/instance/ | awk '/region/ {print $3}' | sed 's/[\"\,]//g')
        OCI_REGION="${OCI_REGION:-}"
        if [ -n "${OCI_REGION}" ]; then
                if [ "${OCI_REGION}" = "iad" ]; then
                        OCI_REGION="ash"
                elif [ "${OCI_REGION}" = "eu-frankfurt-1" ]; then
                        OCI_REGION="fra"
                else
                        : # phx
                fi
		export KUBE_REPO_PREFIX=container-registry-${OCI_REGION}.oracle.com/kubernetes
        fi
   fi
fi

if [ ! -d "/var/run/kubeadm/" ]; then
	mkdir -p /var/run/kubeadm
fi

case "${1:-}" in
  up)
  shift

  kubeadm::up "$@"

  if grep -q "\[kubeadm\]\ WARNING" /tmp/.kubeadm.out; then
	grep "\[kubeadm\]\ WARNING" /tmp/.kubeadm.out  | tail -n2
  fi

  printf "\n[===> PLEASE DO THE FOLLOWING STEPS BELOW: <===]\n"
  tail -n18 /tmp/.kubeadm.out | head -n9
  if [ -z "${KUBE_REPO_PREFIX:-}" ]; then
  	tail -6 /tmp/.kubeadm.out | sed "s/kubeadm/kubeadm-setup.sh/g"
  else
	tail -6 /tmp/.kubeadm.out | sed "s|kubeadm|export KUBE_REPO_PREFIX=${KUBE_REPO_PREFIX} \&\& kubeadm-setup.sh|g"
	rm -f /tmp/flannel.yaml
	rm -f /tmp/dashboard.yaml
  fi
  rm /tmp/.kubeadm.out
  ;;
  down)
  shift

  kubeadm::down "$@"

  ;;
  join)
  shift

  kubeadm::join "$@"

  ;;
  restart|stop)
  kubeadm::clusops "$@"
  ;;
  backup)
  shift
  kubeadm::etcd backup "$@"
  ;;
  restore)
  shift
  kubeadm::etcd restore "$@"
  ;;
  upgrade)
  shift
  kubeadm::upgrade "$@"
  ;;
  *)
  print_usage
  ;;
esac
