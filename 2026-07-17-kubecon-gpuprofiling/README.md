# Profiling GPU Memory for KubeRay Training Jobs on AKS with Anyscale

This project stands up an end-to-end environment for **profiling GPU workloads** on AKS. The goal: run a KubeRay training job on an [Anyscale](https://learn.microsoft.com/azure/anyscale-on-azure/overview) cloud backed by AKS, then use GPU profiling to see what the training code is actually doing to the GPU (memory utilization, kernel activity) so you can reason about efficiency and bottlenecks.

The profiling signal comes from [Inspektor Gadget](https://www.inspektor-gadget.io/)'s GPU observability, exported two ways:

- **Metrics** (GPU utilization, memory, temperature) scraped into **Azure Monitor managed Prometheus** and visualized in **Azure Managed Grafana**.
- **Continuous profiles** collected by **Grafana Pyroscope** running in-cluster, surfaced in Grafana as a Pyroscope data source so you can drill into GPU memory usage over time and correlate it with the training run.

## What Terraform creates

Core platform:

- **Resource group** (`rg-gpuprofiling<NN>` by default, or the name set in the `resource_group_name` variable) holding everything.
- **AKS Automatic cluster** (deployed via AzAPI) with a system-assigned identity, Gateway API + Istio-based app routing enabled, Azure Monitor metrics (managed Prometheus) and Container Insights turned on, OpenTelemetry auto-instrumentation enabled, and deployment safeguards that exclude the `anyscale-operator`, `inspektor-gadget`, and `gadget` namespaces.
- **GPU node pool manifest** (`nvidia-nodepool.yaml`, generated from [nvidia-nodepool.tmpl](./nvidia-nodepool.tmpl)) that defines a Karpenter/NAP `AKSNodeClass` + `NodePool` for the fully managed GPU experience (AKS-managed NVIDIA drivers). VM size is controlled by the `nvidia_sku_name` variable (default `Standard_NV72ads_A10_v5`). Nodes are labeled `nvidia.com/gpu.product=NVIDIA-<accelerator>`, the node selector the Anyscale operator puts on GPU pods.

Observability and profiling:

- **Inspektor Gadget** installed as an AKS extension with `gpuObservability.enabled` and `azureMonitor.enabled`.
- **Grafana Pyroscope** installed via Helm into the `gadget` namespace, exposed on an internal load balancer fronted by an Azure Private Link Service (PLS) so Managed Grafana can reach it privately. Its filesystem bucket is on the data volume (`/data/shared`), so profiles older than four hours stay queryable. Set `pyroscope_persistent_volume_size` to keep profiles on a persistent volume instead of the chart's `emptyDir`.
- **Azure Managed Grafana** (v12) integrated with the Azure Monitor workspace, with a managed private endpoint to the Pyroscope PLS.
- **Azure Monitor workspace** (managed Prometheus) with data collection endpoints/rules, recording rules, and alert rule groups, plus a **Log Analytics workspace** and **Application Insights** with OTLP logs/metrics/traces endpoints.

> [!IMPORTANT]
> Monitoring is wired up end to end for maximum signal during the demo, mirroring Azure's standard managed Prometheus + Container Insights onboarding. The Linux recording rule groups (`node`, `k8s`, `ux` in [prometheus.tf](./prometheus.tf)) are enabled and the Windows group (`uxw`) is disabled, matching the portal defaults. The main ingestion drivers here are Container Insights collecting container logs from **all** namespaces (`namespaceFilteringMode: Off`, ContainerLogV2) into Log Analytics, and managed Prometheus metric ingestion into the Azure Monitor workspace. The minimal ingestion profile (Azure's default cost control for scraped metrics) is on by default, but full-cluster log collection still adds up. For cost-sensitive or production environments, scope this down: enable namespace filtering, disable recording rule groups you do not need, and/or increase collection intervals.

Anyscale (through the Anyscale Clouds resource provider, `Anyscale.Platform`, the same API the Azure portal's **Anyscale clouds** > **Create** flow uses):

- **Anyscale on Azure agreement** (`Anyscale.Platform/agreements/default`) accepted once per subscription when `accept_anyscale_platform_agreement` is `true` (the default). The portal accepts it on its **Review + submit** tab; Terraform, CLI, and ARM template deployments must accept it before creating a cloud.
- **Azure Container Registry** (Standard) and a **storage account** (HNS enabled, private blob container) used as the Anyscale cloud's image registry and object storage.
- **User-assigned managed identity** with a federated credential for the Anyscale operator.
- **Anyscale Cloud** and **Cloud Resource** (`Anyscale.Platform/clouds` and `clouds/cloudResources`, API version `2026-09-01`) via AzAPI, wired to the ACR and storage account.
- **Anyscale operator** installed as an AKS extension (`Anyscale.AKS.Operator`), configured to route ingress through the Istio gateway (`anyscale-gateway.yaml`, generated from [anyscale-gateway.tmpl](./anyscale-gateway.tmpl)). The operator authenticates to the Anyscale control plane with Microsoft Entra workload identity. Terraform also registers a GPU instance type (`anyscale_gpu_instance_type`) and GPU tolerations so Ray GPU pods can run on the `nvidia` node pool.
- **Role assignments**: Storage Blob Data Owner, AcrPush, Container Registry Tasks Contributor (identity), AcrPull (kubelet), AKS RBAC Cluster Admin, Anyscale Platform Contributor (the user running Terraform, on the Anyscale cloud), Grafana Admin, and Monitoring Data Reader (Grafana identity).

## Prerequisites

Install the following tools:

- [Terraform](https://developer.hashicorp.com/terraform/install)
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (to apply the GPU node pool manifest and inspect the cluster)
- [kubelogin](https://azure.github.io/kubelogin/) (used by the Terraform Helm provider to authenticate to the AKS API server; `az aks install-cli` installs both kubectl and kubelogin)
- [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli) (optional: to verify the Anyscale cloud and submit jobs after signing in)
- [jq](https://jqlang.github.io/jq/) (used to read Terraform outputs)

You need these permissions (see [Anyscale on Azure identity and access](https://learn.microsoft.com/azure/anyscale-on-azure/identity-access)):

- **Owner** on the subscription, or **Contributor** plus **User Access Administrator**. Terraform creates the cluster, the Anyscale cloud, and role assignments.
- After deployment, day-to-day Anyscale work needs only Anyscale platform roles on the cloud resource. Terraform grants **Anyscale Platform Contributor** to the user who runs it. Assign **Anyscale Platform Reader** or higher to anyone else who signs in to the [Anyscale console](https://console.azure.anyscale.com) (cloud resource > **Access control (IAM)**). Subscription Owner or Contributor alone doesn't grant Anyscale access.

> [!NOTE]
> The [Anyscale on Azure quickstart](https://learn.microsoft.com/azure/anyscale-on-azure/quickstart-azure-cli) lists a one-time step per Microsoft Entra tenant: create a service principal for Anyscale's Entra application (`az ad sp create --id 086bc555-6989-4362-ba30-fded273e432b`), which requires permission to create service principals from external tenants. This configuration doesn't create it. In a November 2026 validation of this demo, the service principal didn't exist in the tenant, yet the operator authenticated with workload identity and Anyscale jobs created through Azure Resource Manager ran to completion (console sign-in wasn't part of that test). If your tenant does require it (for example, the operator can't get a token for the `api://086bc555-6989-4362-ba30-fded273e432b` audience), have someone with that permission run the command once, then rerun `terraform apply`.

Then prepare your Azure subscription:

- Authenticate the Azure CLI to a subscription with the following resource providers registered:
  - Anyscale.Platform
  - Microsoft.Authorization
  - Microsoft.ContainerRegistry
  - Microsoft.ContainerService
  - Microsoft.Dashboard
  - Microsoft.Insights
  - Microsoft.KubernetesConfiguration
  - Microsoft.ManagedIdentity
  - Microsoft.Monitor
  - Microsoft.Network
  - Microsoft.OperationalInsights
  - Microsoft.Resources
  - Microsoft.Storage

- Register the AKS preview features used by this configuration and wait until each one shows `Registered` before deploying. `ManagedGPUExperiencePreview` is required to create GPU node pools with AKS-managed NVIDIA drivers (see [Create a fully managed GPU node pool on Azure Kubernetes Service (AKS) (preview)](https://learn.microsoft.com/azure/aks/aks-managed-gpu-nodes?tabs=add-ubuntu-gpu-node-pool%2Cmig-single%2Cdriver-only)). The others back the hosted system components, managed Gateway API, Istio-based app routing, Application Insights auto-instrumentation, and deployment safeguards namespace exclusions configured in [aks.tf](./aks.tf).

  ```bash
  for feature in ManagedGPUExperiencePreview AKS-AutomaticHostedSystemProfilePreview ManagedGatewayAPIPreview AppRoutingIstioGatewayAPIPreview AzureMonitorAppMonitoringPreview SafeguardsPreview; do
    az feature register --namespace Microsoft.ContainerService --name $feature
  done
  az provider register --namespace Microsoft.ContainerService
  ```

- Review the [Anyscale on Azure terms](https://www.anyscale.com/anyscale-on-azure-terms). Terraform accepts them for the subscription through the Anyscale Agreements API (`accept_anyscale_platform_agreement`). To accept them yourself instead, set that variable to `false` and run:

  ```bash
  az rest --method PUT \
    --url "https://management.azure.com/subscriptions/<subscription-id>/providers/Anyscale.Platform/agreements/default?api-version=2026-09-01" \
    --body '{"properties":{}}'
  ```

  Either way, Terraform checks that the agreement is `Active` before it creates the Anyscale cloud.

- Make sure the subscription has vCPU quota for the GPU VM family of `nvidia_sku_name` in `location`. GPU families often default to 0 vCPUs. Check with `az vm list-usage --location <region> -o table` and request an increase if needed.

> [!TIP]
> The AzureRM Terraform provider will automatically register required resource providers during deployment. If your account lacks permission to register providers, register them manually with `az provider register --namespace <provider-name>` before running `terraform apply`.

> [!CAUTION]
> Anyscale on Azure is currently in preview and available in select regions. See [supported regions](https://learn.microsoft.com/azure/anyscale-on-azure/supported-regions) for the latest list. Check the `location` variable in [variables.tf](./variables.tf) for the regions validated by this config.

## Deploy

Login to your Azure account and set the subscription you want to use. The AzureRM provider (v4.35+) reads the subscription from your Azure CLI context, so no `ARM_SUBSCRIPTION_ID` export is needed for local CLI-authenticated runs.

```bash
az login
az account set -s <subscription-id>
```

Review the variables in [variables.tf](./variables.tf) before deploying. Key options:

- `location` - Azure region for most resources (default: `switzerlandnorth`). Choose a region running AKS release `v20260619` or later. Check the [AKS release tracker](https://releases.aks.azure.com/) for the version rolled out to each region.
- `resource_group_name` - Optional resource group name (default: `rg-gpuprofiling<NN>`)
- `anyscale_cloud_location` - Region for the Anyscale cloud resource, must be an Anyscale-supported region (default: `eastus`)
- `nvidia_sku_name` - GPU VM size for the NVIDIA node pool (default: `Standard_NV72ads_A10_v5`)
- `anyscale_gpu_instance_type` - The GPU pod shape (Anyscale instance type) the operator offers in compute configs (default: `8CPU-64GB-1xA10`). Its CPU and memory must fit on one `nvidia_sku_name` node, and `accelerator` must match that SKU's GPU. For example, for `Standard_NC4as_T4_v3` (4 vCPUs, 28 GiB) use `{ name = "2CPU-16GB-1xT4", cpu = 2, memory = "16Gi", accelerator = "T4" }`. The operator splits the shape across the Ray container and its sidecars, so the whole pod requests exactly that CPU.
- `accept_anyscale_platform_agreement` - Accept the Anyscale on Azure agreement for the subscription (default: `true`)
- `pyroscope_persistent_volume_size` - Keep Pyroscope's profiles on a persistent volume of this size, for example `"32Gi"` (default: `null`, the chart's `emptyDir`, which loses all profiles when the pod restarts or moves). To turn it on for an existing deployment, see [Troubleshooting](#troubleshooting).
- `pyroscope_do_not_disrupt` - Add the `karpenter.sh/do-not-disrupt` annotation so Node Autoprovisioning doesn't move the Pyroscope pod (default: `false`)
- `storage_allow_nested_items_to_be_public` - Whether containers in the storage account can be made public (default: `true`, the Azure default). Anyscale uses its managed identity, so `false` blocks public containers without affecting it.

> [!TIP]
> Prefer the portal? **Anyscale clouds** > **Create** in the Azure portal registers an existing AKS cluster through the same resource provider, and it creates its own storage account, managed identity, container registry, and operator extension. That covers what [anyscale.tf](./anyscale.tf), [identity.tf](./identity.tf), [storage.tf](./storage.tf), and [registry.tf](./registry.tf) do here, so use one approach per cluster, not both.

Initialize Terraform and deploy.

```bash
terraform init
terraform apply
```

Read the Terraform outputs into environment variables for the steps that follow.

```bash
read -r \
  RG_NAME \
  AKS_NAME \
  NRG \
  PLS_ID \
  ANYSCALE_CLIENT_ID \
  ANYSCALE_CLOUD_NAME \
  ANYSCALE_CLOUD_ID \
  ANYSCALE_CLOUD_SSO_URL \
  ANYSCALE_CLOUD_RESOURCE_ID \
  GRAFANA_NAME \
  GRAFANA_URL \
  PYROSCOPE_URL <<< "$(terraform output -json | jq -r \
    '[.rg_name.value,
      .aks_name.value,
      .node_resource_group.value,
      .pyroscope_pls_id.value,
      .anyscale_iam_client_id.value,
      .anyscale_cloud_name.value,
      .anyscale_cloud_id.value,
      .anyscale_cloud_sso_url.value,
      .anyscale_cloud_resource_id.value,
      .grafana_name.value,
      .grafana_url.value,
      .pyroscope_url.value] | @tsv')"
```

Log into the AKS cluster.

```bash
az aks get-credentials -g $RG_NAME -n $AKS_NAME
```

Apply the Anyscale Gateway manifest so the Anyscale operator can route ingress through the Istio gateway.

```bash
kubectl apply -f anyscale-gateway.yaml
```

Apply the GPU node pool manifest so Node Autoprovisioning can create GPU nodes (with AKS-managed NVIDIA drivers) on demand when a GPU workload is scheduled.

```bash
kubectl apply -f nvidia-nodepool.yaml
```

For more on the managed GPU experience with Node Autoprovisioning, see [Create a fully managed GPU node pool on Azure Kubernetes Service (AKS) (preview)](https://learn.microsoft.com/azure/aks/aks-managed-gpu-nodes?tabs=nap-managed-node%2Cmig-single%2Cdriver-only).

## Verify

Check that the Anyscale operator and gateway-related pods are running.

```bash
kubectl get po -A
```

Optionally, install the [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli) and sign in with your Microsoft Entra account (you need at least the **Anyscale Platform Reader** role on the cloud resource). You can also open the console from the Azure portal: select **Launch Anyscale** on the Anyscale cloud resource, or open `$ANYSCALE_CLOUD_SSO_URL`.

```bash
export ANYSCALE_HOST=https://console.azure.anyscale.com
anyscale login
```

Verify the cloud is registered and healthy. In CLI commands that take `--cloud`, use the cloud's full ARM resource ID in lowercase (the `anyscale_cloud_name` output, `$ANYSCALE_CLOUD_NAME`), not its short name.

```bash
anyscale cloud list
anyscale cloud verify --id $ANYSCALE_CLOUD_ID
```

## Grafana to Pyroscope connectivity and PLS auto-approval

> [!NOTE]
> On a default deploy (unchanged region and Grafana instance), Terraform already handles this end to end, so no manual steps are required here. Read this section to understand the mechanism, or if you deploy Grafana in a different region and need to set the auto-approval subscription ID.

The Pyroscope service is exposed over an internal load balancer fronted by an Azure Private Link Service (PLS), created by the AKS cloud controller manager via `service.beta.kubernetes.io/azure-pls-*` annotations. Azure Managed Grafana connects to it through a managed private endpoint (MPE).

### What the auto-approval annotation is

When a private endpoint connects to a PLS, the connection starts in a **Pending** state and normally has to be approved before traffic flows. The `service.beta.kubernetes.io/azure-pls-auto-approval` annotation tells the AKS cloud controller manager to automatically approve incoming connections whose private endpoint lives in one of the listed subscriptions, so no manual approval step is needed. Its value is a comma-separated list of subscription IDs (wildcards are not supported).

### Why it is needed here

The AKS node resource group (`MC_*`) is protected by [NRG lockdown](https://aka.ms/aks/nrg_lockdown), which adds an Azure **deny assignment** to that resource group. The PLS is created in the node resource group, so approving the pending connection means writing to `Microsoft.Network/privateLinkServices/privateEndpointConnections` there. Deny assignments are evaluated above all role assignments, so this write is blocked even for a subscription Owner:

```text
RESPONSE 403: DenyAssignmentAuthorizationFailed
... the access is denied because of the deny assignment ... nrg-lockdown
```

No RBAC role can work around a deny assignment, and you cannot add yourself to the AKS-managed exclusions. The cloud controller manager, however, *is* excluded from the deny assignment. So instead of approving the connection ourselves, we set `azure-pls-auto-approval` and let the cloud controller manager perform the approval for us. This keeps NRG lockdown enabled for the rest of the cluster.

The value must be the subscription where the private endpoint actually lives. Managed Grafana provisions the MPE's underlying private endpoint in a **Microsoft-owned platform subscription** (per Grafana instance/region), not your subscription. That value comes from the `pyroscope_pls_auto_approval_subscription_ids` variable in [variables.tf](./variables.tf), whose default matches the region this config was originally validated in. If you deploy Grafana in a different region, look it up from the Pyroscope PLS as shown below.

### Look up the auto-approval subscription ID

`NRG` (node resource group) and `PLS_ID` (Pyroscope PLS resource ID) are exported by the outputs block above. Use `PLS_ID` to read the pending connection's private endpoint subscription:

```bash
az network private-link-service show --ids "$PLS_ID" \
  --query "privateEndpointConnections[].privateEndpoint.id" -o tsv \
  | awk -F'/' '{print $3}'
```

Set that subscription ID in the `pyroscope_pls_auto_approval_subscription_ids` variable (for example in `terraform.tfvars`). Auto-approval only applies to new connection requests, so also recreate the Grafana managed private endpoint (and re-run its wait and refresh steps) so it reconnects and gets approved:

```bash
terraform apply \
  -replace=azurerm_dashboard_grafana_managed_private_endpoint.example \
  -replace=time_sleep.wait_for_pls_auto_approval \
  -replace=azapi_resource_action.grafana_managed_private_endpoint_refresh
```

To check whether the connection has been approved:

```bash
az network private-link-service show --ids "$PLS_ID" \
  --query "privateEndpointConnections[].{sub:privateEndpoint.id, status:privateLinkServiceConnectionState.status}" -o table
```

## Configure Grafana data sources and dashboard

The managed Prometheus data source is already provisioned automatically by Azure Managed Grafana through the Azure Monitor workspace integration (configured in [grafana.tf](./grafana.tf)), so you only need to add the Pyroscope data source.

Once the Pyroscope private endpoint connection is approved (see above), add the Pyroscope data source. Grafana reaches Pyroscope over the managed private endpoint, so `PYROSCOPE_URL` is the private IP on port 4040.

```bash
az grafana data-source create -n "$GRAFANA_NAME" -g "$RG_NAME" --definition "{
  \"name\": \"local-pyroscope\",
  \"uid\": \"local-pyroscope\",
  \"type\": \"grafana-pyroscope-datasource\",
  \"access\": \"proxy\",
  \"url\": \"${PYROSCOPE_URL}\",
  \"jsonData\": { \"keepCookies\": [\"pyroscope_git_session\"] }
}"

az grafana data-source show -n "$GRAFANA_NAME" --data-source local-pyroscope
```

Azure Managed Grafana provisions the Inspektor Gadget **Advanced GPU Observability** dashboard (uid `AdvancedGPUObservability`, in the **Azure Monitor** folder) on current Grafana instances. If it's already there, skip the import; `az grafana dashboard create` returns `400 Bad Request` ("Cannot save provisioned dashboard") because the uid belongs to that provisioned dashboard. On a Grafana instance without it, import it:

```bash
az grafana dashboard create \
  -n "$GRAFANA_NAME" \
  -g "$RG_NAME" \
  --definition "$(curl -sSL https://gist.githubusercontent.com/mqasimsarfraz/fca8e2394beb7454f467cf82785e2ee3/raw/2eb00a3853362bc863c292283041e8e283fe46ed/AdvancedGPUObservability.json)"
```

Open the dashboard.

```bash
echo "${GRAFANA_URL}/d/AdvancedGPUObservability"
```

## Walkthrough: from terraform apply to a profiled end state

These are the steps behind the KubeCon NA 2026 talk "Right-Sizing GPU SKUs on AKS with Function-Level Profiling", with the times measured in East US in November 2026 on `Standard_NC4as_T4_v3` (1x NVIDIA T4, 16 GB). Each step links to its details.

1. **Deploy the platform** ([Deploy](#deploy)): `terraform init` and `terraform apply` take about 25-30 minutes (the AKS cluster about 9). Then apply `anyscale-gateway.yaml` and `nvidia-nodepool.yaml`. No GPU node runs yet: Node Autoprovisioning adds one when a pod requests `nvidia.com/gpu`, and removes it 15 minutes after the last GPU pod ends (`consolidateAfter` in [nvidia-nodepool.tmpl](./nvidia-nodepool.tmpl)).
2. **Connect Grafana to Pyroscope** ([connectivity](#grafana-to-pyroscope-connectivity-and-pls-auto-approval), [data sources](#configure-grafana-data-sources-and-dashboard)): check that the private endpoint connection is **Approved**, add the `local-pyroscope` data source, and open the **Advanced GPU Observability** dashboard.
3. **Run a GPU training job** ([without Anyscale](#run-and-profile-a-gpu-training-job-without-anyscale)): the five-phase TinyGPT job in [gpu-train](./gpu-train). A cold start takes about 7 minutes (about 5.5 for the GPU node with the AKS-managed NVIDIA driver, about 1.5 for the 3.3 GB image), then it trains for 10 minutes.
4. **See GPU memory per pod**: set **Namespace** to `gpu-demo`. **GPU Active Memory by Pod** and **Total GPU Memory** come from Inspektor Gadget through managed Prometheus. They step with each phase: batch 8, batch 32 (more activation memory), a climb while the job keeps a slice of every step's logits until it runs out of GPU memory, a flat stretch while the GPU waits on a slow input pipeline, and the right-sized batch 16.
5. **Find the functions that allocate it**: **GPU Memory Profiles** (Pyroscope) is a flame graph of CUDA allocations by call stack, down to the Python functions: `TinyGPT.forward` and its transformer blocks, and PyTorch's backward pass on the `pt_autograd_0` thread. Totals are bytes passed to `cudaMalloc` in the time range, not memory in use.
6. **Right-size**: the job logs step time, throughput and peak memory per phase. On the T4, batch 16 delivers about 96% of batch 32's throughput with about 57% of its memory, so this model doesn't need a larger GPU. Compare that with GPU VM prices before you pick a SKU.
7. **Do the same on Ray** ([on Anyscale](#run-and-profile-a-kuberay-training-job-on-anyscale)): with **Namespace** `anyscale-operator`, the Ray worker process shows up as `ray::train_tiny`. A cold start takes about 11-13 minutes, because Anyscale's operator also starts a head node and installs PyTorch into the task's runtime environment.
8. **Keep the end state for later**: set `pyroscope_persistent_volume_size` and `pyroscope_do_not_disrupt` so profiles survive Pyroscope restarts and node moves. Completed runs stay viewable with an absolute time range: Azure Monitor keeps managed Prometheus data for 18 months. Between runs, no GPU node runs. For fresh data at a known time, run the same Job from a CronJob with `spec.timeZone` (Kubernetes 1.27 or later).

## Run and profile a GPU training job without Anyscale

[gpu-train/gpu-train.py](./gpu-train/gpu-train.py) trains a small GPT-style model (81.7M parameters) on synthetic tokens in repeating 45-second phases: baseline (batch 8), oversized batch (32), a retained-logits leak (batch 16; it keeps a view of every step's logits until CUDA runs out of memory, which the script catches, or until 75% of GPU memory is allocated), a simulated data-loader stall (batch 16 with 250 ms of CPU work per step), and right-sized (batch 16). It prints one JSON line per phase with step time, tokens per second and peak memory. [gpu-train/gpu-train-job.yaml](./gpu-train/gpu-train-job.yaml) runs it for 10 minutes on one GPU from the `nvidia` node pool.

```bash
ACR_NAME=$(az acr list -g "$RG_NAME" --query "[0].name" -o tsv)
az acr import -n "$ACR_NAME" --source docker.io/pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

kubectl create namespace gpu-demo
kubectl create configmap gpu-train-script -n gpu-demo --from-file=gpu-train/gpu-train.py
sed "s/<acr-name>/$ACR_NAME/" gpu-train/gpu-train-job.yaml | kubectl apply -f -

kubectl get nodeclaims -w                  # a GPU node from the nvidia node pool appears
kubectl logs -n gpu-demo job/gpu-train -f  # one JSON line per phase once training starts
```

While it trains, open **Advanced GPU Observability** with **Namespace** set to `gpu-demo`. Metrics appear within about 1-2 minutes, and flame graphs within about a minute. To compare runs later, open the dashboard with an absolute time range around the run, for example `${GRAFANA_URL}/d/AdvancedGPUObservability?from=<start-ms>&to=<end-ms>&var-namespace=gpu-demo`.

## Run and profile a KubeRay training job on Anyscale

With the cluster, GPU node pool, and Grafana wired up, the demo flow is:

1. **Start a Ray job or workspace on the Anyscale cloud** with a compute config that has a CPU head node (for example `2CPU-8GB`) and one GPU worker group that uses the `anyscale_gpu_instance_type` instance type (min and max 1). Anyscale's operator creates the Ray head and worker pods in the `anyscale-operator` namespace, and Node Autoprovisioning brings up a GPU node from the `nvidia` node pool for the worker.
2. **Run GPU training.** [ray-job/train_ray.py](./ray-job/train_ray.py) is a self-contained example: the driver runs on the head node and launches one Ray task with `num_gpus=1` that trains a small GPT-style model in phases with distinct GPU memory patterns (baseline, oversized batch, a retained-logits leak that ends in a CUDA out-of-memory error, a simulated data-loader stall, and a right-sized batch). PyTorch is installed into the task's runtime environment on the GPU node only. You can also bring your own training code or an Anyscale template.
3. **Profile GPU memory.** While the job runs, open the **Advanced GPU Observability** dashboard and set **Namespace** to `anyscale-operator`:
   - **GPU Active Memory by Pod**, **Total GPU Memory**, and the allocation and free rate panels (managed Prometheus) show GPU memory per Ray pod and process.
   - **GPU Memory Profiles** (Pyroscope) shows CUDA allocations as a flame graph down to the Python frames of the Ray task. Ray worker processes are named `ray::<function>` (truncated to 15 characters, for example `ray::train_tiny`), and PyTorch's backward pass shows up as the `pt_autograd_0` thread.

The point of the exercise is to correlate what the training code is doing with its effect on the GPU: spotting memory that is allocated but idle, oversized batches, or phases of the job that leave the GPU underutilized, so you can tune the workload.

### Option A: Anyscale console or CLI

Sign in to the [Anyscale console](https://console.azure.anyscale.com) (or `anyscale login`), select the cloud, and create a job or workspace with the compute config above. The CLI's `anyscale job submit` uploads the `ray-job` folder for you; give it the same head node and GPU worker group as the Option B example, and pass `--cloud "$ANYSCALE_CLOUD_NAME"`.

### Option B: Azure Resource Manager (no Anyscale sign-in)

Projects and jobs are proxied ARM resources under the cloud, so you can create them with `az rest` and your Azure credentials (you need the **Anyscale Platform Contributor** role on the cloud). Creating a job submits it. ARM can't terminate or retry a running job (use the console or CLI for that), so set `timeout`. In our tests, the resource provider stored `maxRetries: 0` as `5`, so a failing job can be retried several times; set a small explicit value instead.

Upload the job code as a zip with a single top-level folder to the cloud's storage container. The Ray pods read it with the operator's managed identity.

```bash
STORAGE_ACCOUNT=$(az storage account list -g "$RG_NAME" --query "[0].name" -o tsv)
(zip -r /tmp/gpu-job.zip ray-job)
az storage blob upload --account-name "$STORAGE_ACCOUNT" --container-name anyscale-data \
  --name demo-jobs/gpu-job.zip --file /tmp/gpu-job.zip --auth-mode key --overwrite
```

Create a project, then the job:

```bash
CLOUD_ID=$(az resource list -g "$RG_NAME" --resource-type Anyscale.Platform/clouds --query "[0].id" -o tsv)

az rest --method PUT \
  --url "https://management.azure.com${CLOUD_ID}/projects/gpu-profiling-demo?api-version=2026-09-01" \
  --body '{"properties":{}}'

az rest --method PUT \
  --url "https://management.azure.com${CLOUD_ID}/projects/gpu-profiling-demo/jobs/gpu-train-ray-1?api-version=2026-09-01" \
  --body "{
  \"properties\": {
    \"config\": {
      \"imageUri\": \"anyscale/ray:2.55.1-slim-py312-cu124\",
      \"computeConfig\": { \"spec\": { \"options\": [ {
        \"headNode\": { \"name\": \"head\", \"instanceType\": \"2CPU-8GB\" },
        \"workerNodes\": [ { \"name\": \"gpu\", \"instanceType\": \"2CPU-16GB-1xT4\", \"minNodes\": 1, \"maxNodes\": 1, \"marketType\": \"ON_DEMAND\" } ]
      } ] } },
      \"entrypoint\": \"python train_ray.py\",
      \"workingDir\": \"abfss://anyscale-data@${STORAGE_ACCOUNT}.dfs.core.windows.net/demo-jobs/gpu-job.zip\",
      \"envVars\": { \"DURATION_SECONDS\": \"600\", \"PHASE_SECONDS\": \"40\" },
      \"maxRetries\": 1,
      \"timeout\": 3600
    }
  }
}"
```

Replace `2CPU-16GB-1xT4` with your `anyscale_gpu_instance_type` name. Poll the job until `state` is `Succeeded` or `Failed` (`url` links to the job in the Anyscale console):

```bash
az rest --method GET \
  --url "https://management.azure.com${CLOUD_ID}/projects/gpu-profiling-demo/jobs/gpu-train-ray-1?api-version=2026-09-01" \
  --query "{state:properties.state, url:properties.url}"
```

Watch the Ray pods and GPU nodes come up:

```bash
kubectl get pods -n anyscale-operator -l ray-node-type -o wide
kubectl get nodeclaims
```

Expect a cold start of roughly 10 to 15 minutes before training starts. A new GPU node takes about 5.5 minutes to become ready (Node Autoprovisioning plus the AKS-managed NVIDIA driver). The operator deletes and re-creates a worker pod that isn't scheduled within about 4 minutes, so the first worker pod is usually replaced once. The operator creates the Ray head pod only after the GPU worker is scheduled. Images and the PyTorch runtime environment then take a few more minutes.

### After a session

A finished job tears down its Ray pods, and Node Autoprovisioning removes the idle GPU node after the `nvidia` node pool's `consolidateAfter` (15 minutes). Projects, jobs, and compute configs are records in the Anyscale control plane and don't run anything when idle. To remove a job record, wait until it's in a terminal state, then delete it (`az rest --method DELETE` on the job URL). Deleting a running job returns `409`, and compute configs can't be deleted.

## Cleanup

Stop any running Anyscale jobs, workspaces, and services first. The operator must be running for Anyscale to tear them down. Then delete the Anyscale cloud resource and cloud before the cluster, in the order the [quickstart's cleanup](https://learn.microsoft.com/azure/anyscale-on-azure/quickstart-azure-cli#clean-up-resources) describes, and finally destroy the rest:

```bash
CLOUD_ID=$(az resource list -g "$RG_NAME" --resource-type Anyscale.Platform/clouds --query "[0].id" -o tsv)
az resource delete --ids "${CLOUD_ID}/cloudResources/default"
az resource delete --ids "${CLOUD_ID}"
terraform destroy
```

`terraform destroy` on its own removes the operator extension before the Anyscale cloud, and the Anyscale control plane can then reject the cloud delete with `409` while it still tracks active clusters.

## Troubleshooting

- **Operator extension install fails with a Marketplace terms or purchase error.** The documented resource provider flow doesn't include accepting Marketplace terms, but if your subscription reports that the `anyscale-operator` plan's terms aren't accepted, accept them and rerun `terraform apply`:

  ```bash
  az vm image terms accept --publisher anyscale1750870039553 --offer anyscale-operator-aks --plan anyscale-operator
  ```

- **`Cannot update fields in the existing cloud resource default` (400 FailedPrecondition).** The Anyscale resource provider doesn't allow updates to an existing cloud resource, so Terraform ignores changes to `cloudStorageBucketEndpoint` on clouds created before this configuration started trimming its trailing slash. Recreate the cloud resource to change it.
- **Pyroscope profile history disappears.** By default Pyroscope stores profiles on `emptyDir` storage, and Node Autoprovisioning can consolidate the node it runs on, which restarts it with an empty store. Set `pyroscope_persistent_volume_size` (for example `"32Gi"`) and `pyroscope_do_not_disrupt = true`. For a quick fix without Terraform, `kubectl annotate pod pyroscope-0 -n gadget karpenter.sh/do-not-disrupt=true` keeps the pod in place until it's re-created.
- **Turning on `pyroscope_persistent_volume_size` for an existing deployment.** The chart adds a volume claim template to the Pyroscope StatefulSet, and Kubernetes doesn't allow changing that on an existing StatefulSet. Delete only the StatefulSet object first; its pod and the Service stay, so the Private Link Service and Grafana's private endpoint aren't affected:

  ```bash
  kubectl delete statefulset pyroscope -n gadget --cascade=orphan
  terraform apply
  ```

  Helm re-creates the StatefulSet, which adopts the running pod but can't add the volume to it, so the apply waits and fails after about 5 minutes with `context deadline exceeded`. Delete the pod so the StatefulSet re-creates it with the volume, then run `terraform apply` again to record the release as deployed. Profiles stored in the old `emptyDir` are lost.

  ```bash
  kubectl delete pod pyroscope-0 -n gadget
  kubectl get pvc -n gadget          # data-pyroscope-0 Bound
  terraform apply
  ```

- **Grafana shows no Pyroscope profiles older than about four hours.** Pyroscope's querier reads data older than `querier.query_store_after` (4 hours) from its bucket. The chart's default filesystem bucket (`./data-shared`, which resolves to `/data-shared`) isn't writable for the non-root Pyroscope user, so block uploads failed and older profiles couldn't be queried. [pyroscope.tf](./pyroscope.tf) now puts the bucket on the data volume (`storage.filesystem.dir: /data/shared`).
