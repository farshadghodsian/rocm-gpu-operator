#!/bin/bash
#
# Copyright (c) Advanced Micro Devices, Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the \"License\");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an \"AS IS\" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
#limitations under the License.
#

# collect tech support logs
# usage:
#    techsupport_dump.sh node-name/all
#
set -e

# generate a uuid to mark the techsupport daemonset
# so that the concurrent techsupport run won't affect each other
UUID=$(uuidgen)

TECH_SUPPORT_FILE=techsupport-${UUID}-$(date "+%F_%T" | sed -e 's/:/-/g')
DEFAULT_RESOURCES="nodes events"
NFD_RESOURCES="pods daemonsets deployments configmap"
KMM_RESOURCES="pods daemonsets deployments modules configmap"
GPUOPER_RESOURCES="pods daemonsets deployments deviceconfig configmap"

OUTPUT_FORMAT="json"
WIDE=""
red='\033[0;31m'
green='\033[0;32m'
clr='\033[0m'

usage() {
	echo -e "$0 [-w] [-o yaml/json] [-k kubeconfig] <node-name/all>"
	echo -e "   [-w] wide option "
	echo -e "   [-o yaml/json] output format, yaml/json(default)"
	echo -e "   [-k kubeconfig] path to kubeconfig(default ~/.kube/config)"
	exit 0
}

log() {
	echo -e "${green}[$(date +%F_%T) techsupport]$* ${clr}"
}

die() {
	echo -e "${red}$* ${clr}" && exit 1
}

pod_logs() {
	NS=$1
	FEATURE=$2
	NODE=$3
	PODS=$4

	[ -z ${PODS} ] && return
	KNS="${KUBECTL} -n ${NS}"
	mkdir -p ${TECH_SUPPORT_FILE}/${NODE}/${FEATURE}
	for lpod in ${PODS}; do
		pod=$(basename ${lpod})
		log "   ${NS}/${pod}"
		${KNS} logs "${pod}" --all-containers >${TECH_SUPPORT_FILE}/${NODE}/${FEATURE}/${NS}_${pod}.txt
		${KNS} logs -p "${pod}" --all-containers --tail 1 >/dev/null 2>&1 && ${KNS} logs -p "${pod}" >${TECH_SUPPORT_FILE}/${NODE}/${FEATURE}/${NS}_${pod}_previous.txt
	done
	echo ${PODS} >${TECH_SUPPORT_FILE}/${node}/${FEATURE}/pods.txt
}

while getopts who:k: opt; do
	case ${opt} in
	w)
		WIDE="-o wide"
		;;
	o)
		OUTPUT_FORMAT="${OPTARG}"
		;;
	k)
		KUBECONFIG="--kubeconfig ${OPTARG}"
		;;
	h)
		usage
		;;
	?)
		usage
		;;
	esac
done
shift "$((OPTIND - 1))"
NODES=$@
KUBECTL="kubectl ${KUBECONFIG}"

[ -z "${NODES}" ] && die "node-name/all required"

rm -rf ${TECH_SUPPORT_FILE}
mkdir -p ${TECH_SUPPORT_FILE}
${KUBECTL} version >${TECH_SUPPORT_FILE}/kubectl.txt || die "${KUBECTL} failed"

NFD_NS=$(${KUBECTL} get pods --no-headers -A -l app.kubernetes.io/name=node-feature-discovery | awk '{ print $1 }' | sort -u | head -n1)
KMM_NS=$(${KUBECTL} get pods --no-headers -A -l app.kubernetes.io/name=kmm | awk '{ print $1 }' | sort -u | head -n1)
GPUOPER_NS=$(${KUBECTL} get pods --no-headers -A -l app.kubernetes.io/name=gpu-operator-charts | awk '{ print $1 }' | sort -u | head -n1)

# if nothing is found based on the above command
# it is possible that the cluster is OpenShift cluster and operators were deployed by OLM
# try to use alternative approach to collect info
if [ -z "$NFD_NS" ]; then
	NFD_NS=$(${KUBECTL} get pods --no-headers -A | grep -i nfd-controller-manager | awk '{ print $1 }' | sort -u | head -n1)
fi
if [ -z "$KMM_NS" ]; then
	KMM_NS=$(${KUBECTL} get pods -A | grep -i kmm-operator-controller | awk '{ print $1 }' | sort -u | head -n1)
fi
if [ -z "$GPUOPER_NS" ]; then
	GPUOPER_NS=$(${KUBECTL} get pods -A | grep -i amd-gpu-operator-controller-manager | awk '{ print $1 }' | sort -u | head -n1)
fi

[ -z "${GPUOPER_NS}" ] && die "no gpu operator"

echo -e "NFD_NAMESPACE:$NFD_NS \nKMM_NAMESPACE:$KMM_NS \nGPUOPER_NAMESPACE:$GPUOPER_NS" >${TECH_SUPPORT_FILE}/namespace.txt
log "NFD_NAMESPACE:$NFD_NS"
log "KMM_NAMESPACE:$KMM_NS"
log "GPUOPER_NAMESPACE:$GPUOPER_NS \n"

# default namespace
for resource in ${DEFAULT_RESOURCES}; do
	${KUBECTL} get -A ${resource} ${WIDE} >${TECH_SUPPORT_FILE}/${resource}.txt 2>&1
	${KUBECTL} describe -A ${resource} >>${TECH_SUPPORT_FILE}/${resource}.txt 2>&1
	${KUBECTL} get -A ${resource} -o ${OUTPUT_FORMAT} >${TECH_SUPPORT_FILE}/${resource}.${OUTPUT_FORMAT} 2>&1
done

# nfd namespace
log "nfd:"
for resource in ${NFD_RESOURCES}; do
	log "   ${NFD_NS}/${resource}"
	mkdir -p ${TECH_SUPPORT_FILE}/nfd/
	${KUBECTL} get -n ${NFD_NS} ${resource} ${WIDE} >${TECH_SUPPORT_FILE}/nfd/${resource}.txt 2>&1
	${KUBECTL} describe -n ${NFD_NS} ${resource} >>${TECH_SUPPORT_FILE}/nfd/${resource}.txt 2>&1
	${KUBECTL} get -n ${NFD_NS} ${resource} -o ${OUTPUT_FORMAT} >${TECH_SUPPORT_FILE}/nfd/${resource}.${OUTPUT_FORMAT} 2>&1
done

log "kmm:"
# kmm namespace
for resource in ${KMM_RESOURCES}; do
	log "   ${KMM_NS}/${resource}"
	mkdir -p ${TECH_SUPPORT_FILE}/kmm/
	${KUBECTL} get -n ${KMM_NS} ${resource} ${WIDE} >${TECH_SUPPORT_FILE}/kmm/${resource}.txt 2>&1
	${KUBECTL} describe -n ${KMM_NS} ${resource} >>${TECH_SUPPORT_FILE}/kmm/${resource}.txt 2>&1
	${KUBECTL} get -n ${KMM_NS} ${resource} -o ${OUTPUT_FORMAT} >${TECH_SUPPORT_FILE}/kmm/${resource}.${OUTPUT_FORMAT} 2>&1
done
log "gpu-operator: "
# gpu oper namespace
for resource in ${GPUOPER_RESOURCES}; do
	log "   ${GPUOPER_NS}/${resource}"
	mkdir -p ${TECH_SUPPORT_FILE}/gpuoper/
	${KUBECTL} get -n ${GPUOPER_NS} ${resource} ${WIDE} >${TECH_SUPPORT_FILE}/gpuoper/${resource}.txt 2>&1
	${KUBECTL} describe -n ${GPUOPER_NS} ${resource} >>${TECH_SUPPORT_FILE}/gpuoper/${resource}.txt 2>&1
	${KUBECTL} get -n ${GPUOPER_NS} ${resource} -o ${OUTPUT_FORMAT} >${TECH_SUPPORT_FILE}/gpuoper/${resource}.${OUTPUT_FORMAT} 2>&1
done

CONTROL_PLANE=$(${KUBECTL} get nodes -l node-role.kubernetes.io/control-plane | grep -w Ready | awk '{print $1}')
# logs
if [ "${NODES}" == "all" ]; then
	# make sure that the nodes is a well-formatted list of all node names
	NODES=$(${KUBECTL} get nodes | grep -w Ready | awk '{print $1}' | awk '{printf "%s ", $0}' | sed 's/ $//')
else
	NODES=$(echo "${NODES} ${CONTROL_PLANE}" | tr ' ' '\n' | sort -u)
fi

cat <<EOF >/tmp/techsupport-${UUID}.json
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: techsupport-${UUID}
  labels:
    app: techsupport-${UUID}
spec:
  selector:
    matchLabels:
      app: techsupport-${UUID}
  template:
    metadata:
      labels:
        app: techsupport-${UUID}
    spec:
      containers:
      - name: busybox
        image: busybox:1.37
        securityContext:
          privileged: true
        args:
        - sleep
        - 1h
EOF
${KUBECTL} apply -f /tmp/techsupport-${UUID}.json

cleanup() {
        ${KUBECTL} delete -f /tmp/techsupport-${UUID}.json
}

trap cleanup EXIT

log "logs:"
nodeList=($NODES)
for node in "${nodeList[@]}"; do
	log " ${node}:"
	${KUBECTL} get nodes ${node} | grep -w Ready >/dev/null || continue
	mkdir -p ${TECH_SUPPORT_FILE}/${node}
	${KUBECTL} describe nodes ${node} >${TECH_SUPPORT_FILE}/${node}/${node}.txt || continue

	# nfd pod logs
	KNS="${KUBECTL} -n ${NFD_NS}"
	NFD_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} -l "app.kubernetes.io/name=node-feature-discovery" || continue)
	if [ -z "$NFD_PODS" ]; then
		NFD_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} | grep -i nfd- || continue)
	fi
	pod_logs $NFD_NS "nfd" $node $NFD_PODS

	# kmm pod logs
	KNS="${KUBECTL} -n ${KMM_NS}"
	KMM_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} -l "app.kubernetes.io/name=kmm" || continue)
	if [ -z "$KMM_PODS" ]; then
		KMM_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} | grep -i kmm-operator- || continue)
	fi
	pod_logs $KMM_NS "kmm" $node $KMM_PODS

	# metrics exporter pod logs
	KNS="${KUBECTL} -n ${GPUOPER_NS}"
	EXPORTER_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} -l "app.kubernetes.io/name=metrics-exporter" || continue)
	if [ -z "$EXPORTER_PODS" ]; then
		EXPORTER_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} | grep -i metrics-exporter- || continue)
	fi
	pod_logs $GPUOPER_NS "metrics-exporter" $node $EXPORTER_PODS

	# device config manager pod logs
	KNS="${KUBECTL} -n ${GPUOPER_NS}"
	DEVICE_CONFIG_MANAGER_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} -l "app.kubernetes.io/name=device-config-manager" || continue)
	pod_logs $GPUOPER_NS "device-config-manager" $node $DEVICE_CONFIG_MANAGER_PODS
	
	# device plugin pod logs
	DEVICE_PLUGIN_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} | grep -i device-plugin- || continue)
	pod_logs $GPUOPER_NS "device-plugin" $node $DEVICE_PLUGIN_PODS

	# node labeller pod logs
	NODE_LABELLER_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} | grep -i node-labeller- || continue)
	pod_logs $GPUOPER_NS "node-labeller" $node $NODE_LABELLER_PODS

	# test runner pod logs
	TEST_RUNNER_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} | grep -i test-runner- || continue)
	pod_logs $GPUOPER_NS "test-runner" $node $TEST_RUNNER_PODS

	# operator pod logs
	GPUOPER_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} -l "app.kubernetes.io/name=gpu-operator-charts" || continue)
	if [ -z "$GPUOPER_PODS" ]; then
		GPUOPER_PODS=$(${KNS} get pods -o name --field-selector spec.nodeName=${node} | grep -i amd-gpu-operator-controller-manager || continue)
	fi
	pod_logs $GPUOPER_NS "gpu-operator" $node $GPUOPER_PODS

	# node logs
	dbgpods=$(${KUBECTL} get pods -o name --field-selector spec.nodeName=${node} -l "app=techsupport-${UUID}" || continue)

	# wait for the debug pod
	for dbgpod in ${dbgpods}; do
		${KUBECTL} wait --for=condition=Ready=true ${dbgpod} >/dev/null
		log "   lsmod"
		${KUBECTL} exec ${dbgpod} -- sh -c "lsmod | grep amdgpu || true" >${TECH_SUPPORT_FILE}/${node}/lsmod.txt
		log "   dmesg"
		${KUBECTL} exec ${dbgpod} -- sh -c "dmesg || true" >${TECH_SUPPORT_FILE}/${node}/dmesg.txt
	done
done

tar cfz ${TECH_SUPPORT_FILE}.tgz ${TECH_SUPPORT_FILE} && rm -rf ${TECH_SUPPORT_FILE} && log "${TECH_SUPPORT_FILE}.tgz is ready"
