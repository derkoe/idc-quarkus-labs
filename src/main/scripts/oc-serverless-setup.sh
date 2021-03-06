#!/bin/bash
set -e

script_dir=$(dirname $0)


############
## Settings
############
container_runtime=podman
container_runtime_push_options="--quiet --tls-verify=false"

postgresql_pod_name=postgresql

spring_project=spring
spring_local_image_name=spring/todo
spring_pod_name=spring-boot
spring_pod_image=${spring_project}/todo

quarkus_jvm_project=quarkus-jvm
quarkus_jvm_local_image_name=quarkus-jvm/todo
quarkus_jvm_pod_name=quarkus-jvm
quarkus_jvm_pod_image=${quarkus_jvm_project}/todo

quarkus_native_project=quarkus-native
quarkus_native_local_image_name=quarkus-native/todo
quarkus_native_pod_name=quarkus-native
quarkus_native_pod_image=${quarkus_native_project}/todo

go_project=go
go_local_image_name=go/hello
go_pod_name=spring-boot
go_pod_image=${go_project}/hello


project_cpu_limit=8
project_mem_limit=2Gi
pod_cpu_limit=100m
spring_pod_memory_limit=256M
quarkus_jvm_pod_memory_limit=128M
quarkus_native_pod_memory_limit=50M

psql_db_name=todo-db
psql_db_host=localhost
psql_db_user=todo
psql_db_password=todo

container_runtime=podman

if [ "$(uname)" == "Darwin" ]; then
  container_runtime=docker
  container_runtime_push_options=""
fi


#############
## Functions
#############

function verify_oc_cli {
  if ! which oc > /dev/null 2>&1; then
    echo "You need to have the oc cli on the path"
    exit 1
  fi
}

function check_authenticated {
  if ! oc whoami > /dev/null 2>&1; then
    echo "You need to be authenticated to a cluster"
    exit 2
  fi
}

function check_admin {
  local whoami=$(oc whoami)
  if ! [ "$whoami" = "opentlc-mgr" ] || [ "$whoami" = "kube:admin" ]; then
    echo "You need to be authenticated as an admin"
    exit 3
  fi
}

function container_registry_login {
  ${container_runtime} login -u $1 -p $2 $3 > /dev/null
}

function create_project {
  oc new-project $1 > /dev/null
  #oc policy add-role-to-user admin user0 -n $1 > /dev/null
}

function tag_and_upload_image {
  ${container_runtime} tag $1:latest $2:latest > /dev/null
  ${container_runtime} push ${container_runtime_push_options} $2:latest > /dev/null
}

function create_postgresql_in_project {
  oc new-app -e POSTGRESQL_USER=todo -e POSTGRESQL_PASSWORD=todo -e POSTGRESQL_DATABASE=todo-db postgresql -e POSTGRESQL_MAX_CONNECTIONS=400 -n $1 >/dev/null
}

function create_knative_operator_subscription {
  CS_NS=$(oc get catalogsources --all-namespaces | tail -1 | awk '{print $1}')
  OPERATOR_NS=$(oc get og --all-namespaces | grep global-operators | awk '{print $1}')

  cat <<-EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator-sub
  generateName: serverless-operator-
  namespace: $OPERATOR_NS
spec:
  source: serverless-operator
  sourceNamespace: $CS_NS
  name: serverless-operator
  channel: techpreview
EOF
}

function install_knative_serving {
  oc apply -f ${script_dir}/../serverless/serving.yaml
}

function knative_ready {
  local _status=$(oc get knativeserving/knative-serving -n knative-serving --template='{{range .status.conditions}}{{printf "%s=%s\n" .type .status}}{{end}}')
  local _status_dep=$(echo $_status | grep -q "DependenciesInstalled=True")
  local _status_avail=$(echo $_status | grep -q "DeploymentsAvailable=True")
  local _status_success=$(echo $_status | grep -q "InstallSucceeded=True")
  local _status_ready=$(echo $_status | grep -q "Ready=True")

  echo "Status Dep: $_status_dep"
  echo "Status Avail: $_status_avail"
  echo "Status success: $_status_success"
  echo "Status ready: $_status_ready"

  if $_status_dep && $_status_avail && $_status_success && $_status_ready; then
    return 0
  else
    return 1
  fi
}

function install_knative {
  #create_knative_operator_subscription

  if ! $(oc get knativeserving -n knative-serving -o name | grep -q knative-serving); then
  printf "Installing KNative Serving "
    install_knative_serving
    sleep 2
    printf .
    while ! knative_ready; do
      sleep 5
      printf .
    done
    echo "[DONE]"
  else
    echo "Knative already installed"
  fi
}

function start_todo_app {
  local namespace=$1
  shift
  local env="$*"
  
  kn service create todo --image=image-registry.openshift-image-registry.svc:5000/${namespace}/todo ${env} -n ${namespace} > /dev/null
  
  #oc new-app todo:latest -n ${namespace} ${env} > /dev/null
  
  #sleep 1
  #oc expose svc todo -n ${namespace} > /dev/null
  #sleep 1
  
}

function check_availability_todo {
  local namespace=$1
  echo "Pinging the todo app on namespace ${namespace}"
  local route=$(oc get route todo -n ${namespace} -o jsonpath='{.spec.host}') 
  while ! (curl -sf ${route} > /dev/null)
  do
    sleep .5
    printf "."
  done
  echo "[DONE]"
}

verify_oc_cli
check_authenticated
check_admin

install_knative



REGISTRY_ROUTE=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')

container_registry_login $(oc whoami) $(oc whoami -t) $REGISTRY_ROUTE



create_project                ${spring_project}
create_project                ${quarkus_jvm_project}
create_project                ${quarkus_native_project}
create_project                ${go_project}

create_postgresql_in_project  ${spring_project}
create_postgresql_in_project  ${quarkus_jvm_project}
create_postgresql_in_project  ${quarkus_native_project}


tag_and_upload_image ${spring_local_image_name} "${REGISTRY_ROUTE}/${spring_pod_image}"
tag_and_upload_image ${quarkus_jvm_local_image_name} "${REGISTRY_ROUTE}/${quarkus_jvm_pod_image}"
tag_and_upload_image ${quarkus_native_local_image_name} "${REGISTRY_ROUTE}/${quarkus_native_pod_image}"
tag_and_upload_image ${go_local_image_name} "${REGISTRY_ROUTE}/${go_pod_image}"

start_todo_app ${spring_project} --env SPRING_DATASOURCE_URL=jdbc:postgresql://postgresql/todo-db --env SPRING_HTTP_PORT=8080
start_todo_app ${quarkus_jvm_project} --env QUARKUS_DATASOURCE_URL=jdbc:postgresql://postgresql/todo-db --env QUARKUS_HTTP_PORT=8080
start_todo_app ${quarkus_native_project} --env QUARKUS_DATASOURCE_URL=jdbc:postgresql://postgresql/todo-db --env QUARKUS_HTTP_PORT=8080

#kn service create hello --image=image-registry.openshift-image-registry.svc:5000/${go_project}/hello -n ${go_project}

# scale_todo_app ${spring_project} 10
# scale_todo_app ${quarkus_jvm_project} 10
# scale_todo_app ${quarkus_native_project} 10



# Expose the registry 


#oc policy add-role-to-user registry-editor user0

#sleep 2

#