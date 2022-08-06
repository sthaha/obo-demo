#!/usr/bin/env bash
set -e -u -o pipefail

declare -r SCRIPT_PATH=$(readlink -f "$0")
declare -r SCRIPT_DIR=$(cd $(dirname "$SCRIPT_PATH") && pwd)

trap cleanup EXIT INT

declare -a PORT_FORWARDED_PIDS=()

apply() {
	local desc="$1"
	shift
	local f="$1"
	shift
	local show="${1:-yes}"

	echo applying: $desc : $f
	line 40

	if [[ "$show" != silent ]]; then
		bat $f
		sep
		wait_for_key
	fi
	kubectl apply -f $f
}

build() {

	make operator-image bundle bundle-image operator-push bundle-push IMAGE_BASE="local-registry:30000/observability-operator" VERSION=0.0.0-ci CONTAINER_RUNTIME=docker

	#  make operator-push bundle-push PUSH_OPTIONS=--tls-verify=false IMAGE_BASE="local-registry:30000/observability-operator" VERSION=0.0.0-ci

	kubectl wait --for=condition=Established crds --all --timeout=300s
	kubectl create -k deploy/crds/kubernetes
	./tmp/bin/operator-sdk run bundle \
		local-registry:30000/observability-operator-bundle:0.0.0-ci \
		--install-mode AllNamespaces \
		--namespace operators \
		--skip-tls \
		--index-image=quay.io/operator-framework/opm:v1.23.0

	kubectl rollout status deployment observability-operator -n operators

}

header() {
	local txt="$@"

	local len=40
	if [[ ${#txt} -gt $len ]]; then
		len=${#txt}
	fi

	echo -n "━━━━━"
	printf '━%.0s' $(seq $len)
	echo "━━━━━━━"
	echo -e "     $txt"

	echo -n "────"
	printf '─%.0s' $(seq $len)
	echo "────────"

	echo
}

line() {
	local len=${1:-30}

	echo -n "────"
	printf '─%.0s' $(seq $len)
	echo "────────"
}

sep() {
	local len=${1:-30}
	echo -n "    "
	printf '⎯%.0s' $(seq $len)
	echo
}

wait_for_key() {
	echo -en "\n  ﮸ Press a key to continue  ..."
	read -s
	echo
	echo
}

kill_after_key_press() {
	local pid=$1
	shift

	wait_for_key
	kill -INT $pid
}

port_forward() {
	local svc=$1
	shift
	local target=$1
	shift
	local local_port=${1:-$target}

	kubectl get svc "$svc"
	sep
	echo

	echo kubectl port-forward svc/$svc $local_port:$target --address 0.0.0.0 &
	kubectl port-forward svc/$svc $local_port:$target --address 0.0.0.0 &
	PORT_FORWARDED_PIDS+=($!)

	sleep 2
	line
	echo -e "\nopen: http://<your-ip>:$local_port"
}

list_all() {
	local what=$1
	shift
	echo "$what"
	line

	kubectl get "$what" $@
	sep
}

step_000_set_context() {
	header "✨ 0b0 ✨ -< OpenShift Observability Operator >- ✨ 0b0 ✨ "
	echo "  ✶ Deploy a monitoring stack"
	echo "  ✶ Monitor an appliction"
	echo "  ✶ Deploy Thanos Querier"
	echo "  ✶ Deploy another monitoring stack"
	sep
	wait_for_key
}

step_100_set_context() {
	kubectl create ns obo-demo || true
	kubectl config set-context kind-obs-operator --namespace=obo-demo
}

step_110_create_stack() {
	header "Deploy a montoring stack"
	apply "monitoring stack" monitoring-stack.yaml
}

stack_status() {
	local stack=$1
	shift

	echo "❯ run: kubectl get monitoringstack $stack -o jsonpath='{.status.conditions}' | jq -C ."

	kubectl get monitoringstack $stack \
		-o jsonpath='{.status.conditions}' | jq -C .
}

repeat() {
	local what=$1
	shift
	local ans=y

	while [[ "$ans" == "y" ]]; do

		$what "$@"
		sep
		read -p " repeat ? " ans
	done
}

step_120_watch() {
	watch -n 3 -c \
		"kubectl get monitoringstack sample-monitoring-stack" \
		" -o jsonpath='{.status.conditions}' | jq -C ." &
	pid=$!

	sleep 10s
	kill -INT $pid || true

	repeat stack_status sample-monitoring-stack
	wait_for_key
}

step_130_show_running() {
	clear
	header "Show Stack Details"
	echo "  ✶ Prometheus"
	echo "  ✶ Alertmanager"
	sep
	echo
	wait_for_key

	list_all prometheus -l app.kubernetes.io/part-of=sample-monitoring-stack
	list_all alertmanager -l app.kubernetes.io/part-of=sample-monitoring-stack

	wait_for_key
	echo

	list_all statefulsets -l app.kubernetes.io/part-of=sample-monitoring-stack
	list_all services -l app.kubernetes.io/part-of=sample-monitoring-stack
	wait_for_key
}

step_140_show_prom_targets() {
	header "Prometheus up and running"
	port_forward sample-monitoring-stack-prometheus 9090

	line
	echo 'self monitoring: http://<ip>:9090/targets'
	echo 'Run: count by (__name__, job, instance) ({__name__ =~ ".+"})'
	wait_for_key
}

step_300_deploy_sample_app() {
	clear
	header "Deploy an Example App"

	apply "deployment " spy/deployment.yaml silent
	apply "service" spy/service.yaml

	kubectl wait --for=condition=Available deployment prom-spy
	port_forward prom-spy 8080

	echo "Application exposes /metrics"
	echo '{__name__=~ "promhttp.+"}' | clip

	wait_for_key
}

step_310_deploy_servicemon() {
	header "Monitor Example App"
	apply "service-monitor" spy/servicemon.yaml
	wait_for_key
}

step_400_thanos_querier() {
	header "Deploy Thanos Querier"
	apply "querier" thanos-querier.yaml
}

step_410_show_running() {
	header "Thanos Querier - Internals"
	list_all thanosquerier
	sep
	echo
	list_all deployments -l app.kubernetes.io/instance=thanos-querier-example-thanos
	### TODO: why is the label different?
	list_all services -l app.kubernetes.io/instance=example-thanos
	wait_for_key
}

step_420_thanos_querier_running() {
	header "Thanos Querier In Action"
	port_forward thanos-querier-example-thanos 9090 9091

	line
	echo 'count by (__name__, job, instance, prometheus_replica) ({__name__ =~ "promhttp.+"})' | clip
	wait_for_key
}

step_430_create_stack() {
	header "Deploy another stack"
	apply "stack" another-stack.yaml
}

step_440_watch() {
	repeat stack_status another-stack
	port_forward another-stack-prometheus 9090 9092
	wait_for_key

}

cleanup() {
	for pid in ${PORT_FORWARDED_PIDS[@]}; do
		kill -INT $pid 2>/dev/null >&2 || true
	done
}

step_999_thank_you() {

	header " ✨ The End ✨"
	echo
	echo "   Questions: "
	echo "      #forum-monitoring"
	echo "      #observability-operator-users on CoreOS slack"
	echo
	echo "                                        Sunil Thaha"
	line
}

main() {
	export KUBECONFIG=${KUBECONFIG:-~/.kube/cluster/obo}

	fns=($(declare -F | awk '{ print $3 }' | sort | grep step_ | grep -v _skip))

	for x in ${fns[@]}; do
		$x
		sleep 2
	done

	cleanup
	# echo "ran: ${fns[@]}"

	return $?
}

main "$@"
