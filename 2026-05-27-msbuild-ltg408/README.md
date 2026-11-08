# LTG408: The developer experience with AKS Desktop and VS Code

Getting an app from local dev or on‑prem to AKS can be hard to make secure, repeatable, and easy to run. This session shows how AKS Desktop and VS Code speed the developer‑to‑AKS journey, from local Kubernetes workflows and containerization to CI/CD and safe deployments, using built‑in Kubernetes best practices for reliable operations.

```bash
terraform init
terraform apply
az aks get-credentials --resource-group $(terraform output -raw rg_name) --name $(terraform output -raw aks_name)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &
argocd login localhost:8080 --sso --insecure
argocd account get-user-info
```

Use local port 8080 for the port-forward: Argo CD's `global.domain` and the app registration's web redirect URI are both `https://localhost:8080`, so browser sign-in at <https://localhost:8080> only completes on that port.

Optional variables (set them in a `terraform.tfvars` file):

- `resource_group_name` - use a fixed resource group name instead of `rg-buildltg408<xxxx>`.
- `pre_consent_graph_permissions` - defaults to `true`, which grants tenant-wide consent for the Argo CD app and requires an Entra admin role such as Cloud Application Administrator. Set it to `false` if you don't have one; each user then consents to the `openid`, `profile` and `email` permissions at first sign-in, if your tenant's user consent settings allow it.
- `system_node_pool_count` - defaults to `3`. The hosted system profile already runs core system components on AKS-managed infrastructure, so `1` lowers the demo's idle cost.
- `container_insights_interval` - defaults to `1m`. `5m` (the Container Insights cost-optimized interval) cuts Log Analytics ingestion for an idle demo cluster.
- `namespace_resource_quota` - CPU and memory requests and limits of the `team-blue` project. The default (2 CPU and 4 GiB for both) fits one copy of the app. To run the final state below (the app you deploy with AKS desktop plus the copy Argo CD syncs from Git) with room for rolling updates, the autoscaler and Argo CD self-heal, raise the limits:

  ```hcl
  namespace_resource_quota = {
    cpu_request    = "2000m"
    cpu_limit      = "4000m"
    memory_request = "4096Mi"
    memory_limit   = "8192Mi"
  }
  ```

- `foundry_local_auth_enabled` - defaults to `true`. The app authenticates to Microsoft Foundry with workload identity, so you can set it to `false` to turn off API keys, for example when you leave the environment running. The `mf_api_key` output then stops working.

## Walkthrough: from a container image to GitOps

The session takes one app, Contoso Air (a Next.js travel site with an AI chat assistant), to AKS in two ways, in the `team-blue` project that Terraform created:

| Step | Tool | Result in `team-blue` |
|---|---|---|
| 1. Deploy | AKS desktop | `contoso-air` from the public image `ghcr.io/pauldotyu/contoso-air:1.2.0` |
| 2. Manage | AKS desktop | Scaled out, Service on port 80, autoscaler, chat connected to Microsoft Foundry through workload identity (no keys) |
| 3. Make it repeatable | VS Code (AKS extension) + Argo CD | Manifests generated into Git, synced by the Argo CD Application `web` |

You need the Terraform deployment above, [AKS desktop](https://github.com/Azure/aks-desktop/releases) (v0.10.0 or later), and VS Code with the [Azure Kubernetes Service extension](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-aks-tools) (2.7.0 or later) and GitHub Copilot. Two values come from Terraform:

```bash
terraform output -raw mf_api_base_url   # Microsoft Foundry endpoint
terraform output -raw mi_client_id      # client ID of the managed identity the app uses
```

### 1. Deploy with AKS desktop

1. Sign in with Azure, then add the cluster from your subscription and register it.
2. Open **Projects** > `team-blue`. It's an AKS managed namespace with a resource quota, a network policy and role assignments; its `headlamp.dev/project-*` labels make it an AKS desktop project.
3. Select **Deploy Application** > **Container Image** > **Next**, and fill in **Configure**:
   - Basics: Application name `contoso-air`, Container image `ghcr.io/pauldotyu/contoso-air:1.2.0`, Replicas `1`.
   - Networking: Container port (target port) `3000`, internal only.
   - Healthchecks and Resource Limits: keep the defaults (liveness, readiness and startup probes; 100m/500m CPU and 128Mi/512Mi memory).
4. Select **Next**, review the generated manifests, and select **Deploy**.
5. Open the app with `kubectl -n team-blue port-forward svc/contoso-air 8081:3000` and browse to <http://localhost:8081>. The chat answers that no chat provider is configured yet.

### 2. Manage with AKS desktop

1. Scale `contoso-air` to 2 replicas, then look at **Metrics**, **Logs**, **Info** (networking and resource quota) and **Access** (role assignments).
2. On the **Deploy** tab, select **Edit deployment** and change:
   - Networking: turn on **Use custom service port** and set the service port to `80` (the target port stays `3000`).
   - Environment Variables: `CHAT_PROVIDER` = `azure`, `AZURE_OPENAI_ENDPOINT` = the `mf_api_base_url` output, `AZURE_OPENAI_DEPLOYMENT` = `gpt-5.4-mini`, `AZURE_OPENAI_API_VERSION` = `2024-10-21`, `AZURE_OPENAI_CLIENTID` = the `mi_client_id` output.
   - HPA: on, minimum 2 and maximum 4 replicas, 70% CPU.
   - Workload Identity: on, **Use existing identity**, and select the `mi-buildltg408<xxxx>` managed identity. AKS desktop names the service account `contoso-air-sa`, which matches the federated credential Terraform created for `system:serviceaccount:team-blue:contoso-air-sa`, and that identity has the Cognitive Services OpenAI User role on the Foundry account. A new identity wouldn't have that role.
3. Deploy, run `kubectl -n team-blue port-forward svc/contoso-air 8081:80`, and ask the chat a question. It answers through `gpt-5.4-mini` without an API key.

### 3. Make it repeatable with VS Code and Argo CD

1. Fork <https://github.com/pauldotyu/contoso-air>, clone your fork and open it in VS Code. Don't deploy the `src/web/k8s` manifests on its `main` branch as they are: they point at a private registry. Generate your own in the next step.
2. Use the AKS extension's **Develop & Deploy** (Containerization Assist, which uses GitHub Copilot) to generate Kubernetes manifests for `src/web` into `src/web/k8s`. Check the app name (`web`, so it doesn't replace `contoso-air`), the namespace (`team-blue`), the image (a public one such as `ghcr.io/pauldotyu/contoso-air:1.2.0`) and the Service (port 80 to 3000). Apply them to try them out, then commit and push them.
3. Run **AKS: Check Argo CD Status** to confirm that the managed Argo CD extension is running.
4. Run **AKS: Create Argo CD Application** (App name `web`, your repository URL, path `src/web/k8s`, target namespace `team-blue`), then **AKS: Apply Argo CD Application to Cluster**.
5. Open the Argo CD UI (port-forward to 8080 as shown at the top, then <https://localhost:8080> and sign in with Microsoft Entra ID). `web` turns Synced and Healthy within about a minute. From now on, a commit to `src/web/k8s` is a deployment.

### Shortcut: apply the final state from the command line

[`final-state/`](final-state/) holds the end state of all three steps: the AKS desktop result for `contoso-air`, with two placeholders for Terraform outputs, and the Argo CD Application `web`. The Application syncs the manifests of the Microsoft Build LTG408 demo, pinned to a commit so they can't change underneath you. To watch Argo CD sync your own commits, point `repoURL` at your repository and set `targetRevision` to `HEAD`. Both apps together use 2 CPU of limits (four pods at 500m), the whole default quota, so set `namespace_resource_quota` as shown above first.

Bash (`envsubst` comes with GNU gettext):

```bash
export AZURE_OPENAI_ENDPOINT=$(terraform output -raw mf_api_base_url)
export WORKLOAD_IDENTITY_CLIENT_ID=$(terraform output -raw mi_client_id)
envsubst '$AZURE_OPENAI_ENDPOINT $WORKLOAD_IDENTITY_CLIENT_ID' < final-state/contoso-air.yaml | kubectl apply -f -
kubectl apply -f final-state/argocd-application-web.yaml
kubectl -n team-blue rollout status deployment/contoso-air
kubectl -n argocd get application web      # SYNC STATUS Synced, HEALTH STATUS Healthy
kubectl -n team-blue port-forward svc/contoso-air 8081:80
```

PowerShell:

```powershell
$endpoint = terraform output -raw mf_api_base_url
$clientId = terraform output -raw mi_client_id
(Get-Content final-state/contoso-air.yaml -Raw).Replace('${AZURE_OPENAI_ENDPOINT}', $endpoint).Replace('${WORKLOAD_IDENTITY_CLIENT_ID}', $clientId) | kubectl apply -f -
kubectl apply -f final-state/argocd-application-web.yaml
kubectl -n argocd get application web
```

The Argo CD Application, as the AKS extension generates it (with the pinned `targetRevision`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: web
  namespace: argocd
  labels:
    app.kubernetes.io/name: web
    app.kubernetes.io/managed-by: argocd
  annotations:
    aks-extension/docs: "https://argo-cd.readthedocs.io/en/stable/"
spec:
  project: default
  source:
    repoURL: https://github.com/pauldotyu/contoso-air.git
    targetRevision: 74e4c470448a342c5a748b655d47bd74abd7554f
    path: src/web/k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: team-blue
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - Validate=true
    retry:
      limit: 3
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

Reference:

- [Securing Argo CD with Microsoft Entra ID: A Step-by-Step Guide](https://blog.aks.azure.com/2026/04/22/argocd-extension-with-microsoft-entra)