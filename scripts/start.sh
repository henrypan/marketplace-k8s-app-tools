#!/bin/bash
#
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eo pipefail

for i in "$@"
do
case $i in
  --project=*)
    project="${i#*=}"
    shift
    ;;
  --cluster=*)
    cluster="${i#*=}"
    shift
    ;;
  --zone=*)
    zone="${i#*=}"
    shift
    ;;
  --deployer=*)
    deployer="${i#*=}"
    shift
    ;;
  --parameters=*)
    parameters="${i#*=}"
    shift
    ;;
  --entrypoint=*)
    entrypoint="${i#*=}"
    shift
    ;;
  *)
    >&2 echo "Unrecognized flag: $i"
    exit 1
    ;;
esac
done

[[ -z "$project" ]] && >&2 echo "--project required" && exit 1
[[ -z "$cluster" ]] && >&2 echo "--cluster required" && exit 1
[[ -z "$zone" ]] && >&2 echo "--zone required" && exit 1
[[ -z "$deployer" ]] && >&2 echo "--deployer required" && exit 1
[[ -z "$parameters" ]] && >&2 echo "--parameters required" && exit 1
[[ -z "$entrypoint" ]] && entrypoint="/bin/deploy.sh"

gcloud container clusters get-credentials "$cluster" \
    --zone "$zone" \
    --project "$project" 

docker run \
    -i \
    --entrypoint=/bin/bash \
    --rm "${deployer}" \
    -c 'cat /data/schema.yaml' \
> /tmp/schema.yaml

echo "$parameters" > /tmp/values.json

name="$(print_config.py \
    --schema_file=/tmp/schema.yaml \
    --values_file=/tmp/values.json \
    --param '{"x-google-marketplace": {"type": "NAME"}}')"
namespace="$(print_config.py \
    --schema_file=/tmp/schema.yaml \
    --values_file=/tmp/values.json \
    --param '{"x-google-marketplace": {"type": "NAMESPACE"}}')"

app_version="$(cat /tmp/schema.yaml \
  | yaml2json \
  | jq -r 'if .application_api_version
           then .application_api_version
           else "v1alpha1"
           end')"

# Create Application instance.
kubectl apply --namespace="$namespace" --filename=- <<EOF
apiVersion: "app.k8s.io/${app_version}"
kind: Application
metadata:
  name: "${name}"
  namespace: "${namespace}"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: "${name}"
  assemblyPhase: "Pending"
EOF

app_uid=$(kubectl get "applications/$name" \
  --namespace="$namespace" \
  --output=jsonpath='{.metadata.uid}')
app_api_version=$(kubectl get "applications/$name" \
  --namespace="$namespace" \
  --output=jsonpath='{.apiVersion}')

# Provisions external resource dependencies and the deployer resources.
# We set the application as the owner for all of these resources.
echo "${parameters}" \
  | provision.py \
    --schema_file=/tmp/schema.yaml \
    --values_file=/tmp/values.json \
    --deployer_image="${deployer}" \
    --deployer_entrypoint="${entrypoint}" \
  | set_app_labels.py \
    --manifests=- \
    --dest=- \
    --name="${name}" \
    --namespace="${namespace}" \
  | set_ownership.py \
    --manifests=- \
    --dest=- \
    --noapp \
    --app_name="${name}" \
    --app_uid="${app_uid}" \
    --app_api_version="${app_api_version}" \
  | kubectl apply --namespace="$namespace" --filename=-
