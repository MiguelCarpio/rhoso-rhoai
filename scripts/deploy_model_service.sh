#!/bin/bash

set -e

CLUSTER_NAME="${CLUSTER_NAME:-rhoai}"
OPENSHIFT_CLIENT="${OPENSHIFT_CLIENT:-$(which oc)}"

export OS_CLOUD=${OS_CLOUD:-default}
export KUBECONFIG="../clusters/${CLUSTER_NAME}/auth/kubeconfig"

echo ""
echo "========================================="
echo "  Model Service Deployment"
echo "========================================="
echo ""

# Checking the cluster health
echo "[1/6] Checking cluster health..."
if ! ${OPENSHIFT_CLIENT} get clusterversion version -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}' | grep -E -q 'Available=True.*Progressing=False|Progressing=False.*Available=True'; then
  echo "  ✗ Cluster is DEGRADED or UPDATING (Check 'oc get clusterversion')"
  exit 1
fi
echo "  ✓ Cluster is healthy"
echo ""

echo "[2/6] Setting up namespace and persistent storage..."
${OPENSHIFT_CLIENT} create namespace vllm-llama || true

echo "PersistentVolumeClaim:"
cat << EOF | tee /dev/tty | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: huggingface-cache-pvc
  namespace: vllm-llama
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 40Gi
EOF
echo "  ✓ HuggingFace cache PVC created (40Gi)"
echo ""

echo "[3/6] Deploying vLLM application with Llama-3.2-1B-Instruct-FP8 model..."
echo "Deployment:"
cat << EOF | tee /dev/tty | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-llama-deployment
  namespace: vllm-llama
  labels:
    app: vllm-llama
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-llama
  template:
    metadata:
      labels:
        app: vllm-llama
    spec:
      containers:
        - name: vllm-container
          image: registry.redhat.io/rhaiis/vllm-cuda-rhel9
          args:
            - "--model=RedHatAI/Llama-3.2-1B-Instruct-FP8"
            - "--tensor-parallel-size=1"
            - "--host=0.0.0.0"
            - "--port=8000"
          env:
            - name: HF_HUB_OFFLINE
              value: "0"
            - name: VLLM_NO_USAGE_STATS
              value: "1"
          ports:
            - containerPort: 8000
              name: http
              protocol: TCP
          # Adding best-practice security settings.
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - "ALL"
          resources:
            requests:
              cpu: "4"
              memory: "8Gi"
            limits:
              # This requests one NVIDIA GPU. Requires the NVIDIA GPU Operator.
              nvidia.com/gpu: '1'
              cpu: "8"
              memory: "16Gi"
          volumeMounts:
            # Mount the persistent cache volume
            - name: huggingface-cache
              mountPath: /root/.cache/huggingface
            # Mount the shared memory volume
            - name: dshm
              mountPath: /dev/shm
      volumes:
        - name: huggingface-cache
          persistentVolumeClaim:
            claimName: huggingface-cache-pvc
        # Define the 4Gi shared memory volume
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 4Gi
EOF
echo ""

echo "  ⏳ Waiting for deployment to be available (timeout: 30m, downloading model...)..."
${OPENSHIFT_CLIENT} wait --for=condition=Available --timeout=30m deployment/vllm-llama-deployment -n vllm-llama
echo "  ✓ Deployment available"
echo ""

VLLM_POD_NAME=$(${OPENSHIFT_CLIENT} get pods -n vllm-llama -o jsonpath='{.items[0].metadata.name}')

echo "  ⏳ Waiting for application startup to complete (timeout: 10m)..."
timeout 600s bash -c "while ! (${OPENSHIFT_CLIENT} logs pod/${VLLM_POD_NAME} -n vllm-llama | grep 'Application startup complete'); do sleep 10; done"
echo "  ✓ vLLM application started (model: RedHatAI/Llama-3.2-1B-Instruct-FP8)"
echo ""

echo "[4/6] Creating Service to expose the deployment internally..."
echo "Service:"
cat << EOF | tee /dev/tty | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vllm-llama-service
  namespace: vllm-llama
  labels:
    app: vllm-llama
spec:
  selector:
    app: vllm-llama
  ports:
    - protocol: TCP
      port: 8000
      targetPort: 8000
  type: ClusterIP
EOF
echo "  ✓ Service created (ClusterIP, port 8000)"
echo ""

echo "[5/6] Creating Route to expose the service externally..."
echo "Route:"
cat << EOF | tee /dev/tty | ${OPENSHIFT_CLIENT} apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: vllm-llama-route
  namespace: vllm-llama
  labels:
    app: vllm-llama
spec:
  to:
    kind: Service
    name: vllm-llama-service
  port:
    targetPort: 8000
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
echo "  ✓ Route created (TLS edge termination)"
echo ""

echo "[6/6] Configuring inference endpoint access..."
ROUTER_WORKER=$(${OPENSHIFT_CLIENT} get pods -n openshift-ingress -o jsonpath='{.items[0].spec.nodeName}')

# Get the server's port and then find the floating IP attached to it
SERVER_PORT=$(openstack port list --server "${ROUTER_WORKER}" -f value -c ID)
ROUTER_FLOATINGIP=$(openstack floating ip list --port "${SERVER_PORT}" -f value -c "Floating IP Address")

INFERENCE_ENDPOINT=$(${OPENSHIFT_CLIENT} get route -n vllm-llama -o jsonpath='{.items[0].spec.host}')

hosts="# Generated by rhos-vaf for Model Service $CLUSTER_NAME - Do not edit
$ROUTER_FLOATINGIP ${INFERENCE_ENDPOINT}
# End of rhos-vaf $CLUSTER_NAME inference endpoints"

old_hosts=$(awk "/# Generated by rhos-vaf for Model Service $CLUSTER_NAME - Do not edit/,/# End of rhos-vaf $CLUSTER_NAME inference endpoints/" /etc/hosts)

if [ "${hosts}" != "${old_hosts}" ]; then
    echo "Updating /etc/hosts:"
    sudo sed -i "/# Generated by rhos-vaf for Model Service $CLUSTER_NAME - Do not edit/,/# End of rhos-vaf $CLUSTER_NAME inference endpoints/d" /etc/hosts
    echo "$hosts" | sudo tee -a /etc/hosts
    echo "  ✓ /etc/hosts updated with inference endpoint"
else
    echo "  ✓ /etc/hosts already up to date"
fi
echo ""

echo "========================================="
echo "  Model Service Deployment Complete"
echo "========================================="
echo ""
echo "Inference Endpoint: https://${INFERENCE_ENDPOINT}"
echo "Model: RedHatAI/Llama-3.2-1B-Instruct-FP8"
echo "Runtime: vLLM (rhaiis/vllm-cuda-rhel9)"
echo "GPU: 1x NVIDIA"
echo ""
