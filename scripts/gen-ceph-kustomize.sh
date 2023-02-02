#!/bin/bash
#
# Copyright 2022 Red Hat Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.
set -ex

# expect that the common.sh is in the same dir as the calling script
SCRIPTPATH="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
. ${SCRIPTPATH}/common.sh --source-only

NODE_NAMES=$(oc get node -o name -l node-role.kubernetes.io/worker | sed -e 's|node/||' | head -c-1 | tr '\n' ',')
if [ -z "$NODE_NAMES" ]; then
  echo "Unable to determine node name with 'oc' command."
  exit 1
fi

if [ -z "$IMAGE" ]; then
  echo "Unable to determine ceph image."
  exit 1
fi

if [ ! -d ${DEPLOY_DIR} ]; then
      mkdir -p ${DEPLOY_DIR}
fi

pushd ${DEPLOY_DIR}

cat <<EOF >kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ./cluster-test.yaml
namespace: rook-ceph
patches:
- target:
    kind: CephCluster
  patch: |-
    - op: replace
      path: /spec/cephVersion/image
      value: $IMAGE
    - op: replace
      path: /spec/storage
      value:
        nodes:
        - name: $NODE_NAMES
        devices:
        - name: /dev/ceph_vg/ceph_lv_data
    - op: replace
      path: /spec/network
      value:
        hostNetwork: true
EOF

kustomization_add_resources
