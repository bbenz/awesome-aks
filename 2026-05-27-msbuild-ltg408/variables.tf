variable "location" {
  description = "The location/region where most of the resources will be created."
  type        = string
  default     = "westus3"
}

variable "resource_group_name" {
  description = "Optional name for the resource group. When null, defaults to rg-buildltg408<xxxx>."
  type        = string
  default     = null
}

variable "pre_consent_graph_permissions" {
  description = "Create a tenant-wide (AllPrincipals) Microsoft Graph delegated permission grant for the Argo CD app so users aren't prompted for consent at first sign-in. Requires an Entra admin role such as Cloud Application Administrator. Set to false without one; users then consent to openid, profile and email at first sign-in (if the tenant's user consent settings allow it)."
  type        = bool
  default     = true
}

variable "system_node_pool_count" {
  description = "Node count for the systempool agent pool (billed VMs in your subscription). The hosted system profile already runs core system components on AKS-managed infrastructure, so 1 node lowers idle cost for a demo; node auto-provisioning places anything that doesn't fit."
  type        = number
  default     = 3
}

variable "container_insights_interval" {
  description = "Container Insights collection interval (1m to 30m). Longer intervals ingest less Perf and inventory data into Log Analytics; the cost-optimized preset uses 5m."
  type        = string
  default     = "1m"
}

variable "foundry_local_auth_enabled" {
  description = "Allow API-key (local) authentication on the Microsoft Foundry account. The app authenticates with workload identity, so false is safer for a cluster you leave running; mf_api_key then stops working."
  type        = bool
  default     = true
}

variable "namespace_resource_quota" {
  description = "Default resource quota of the team-blue managed namespace (the AKS desktop project). Raise the limits when you run both versions of the app side by side (the one deployed with AKS desktop and the one Argo CD syncs from Git) so rollouts and self-heal have room."
  type = object({
    cpu_request    = string
    cpu_limit      = string
    memory_request = string
    memory_limit   = string
  })
  default = {
    cpu_request    = "2000m"
    cpu_limit      = "2000m"
    memory_request = "4096Mi"
    memory_limit   = "4096Mi"
  }
}

variable "tags" {
  description = "A map of tags to assign to the resources."
  type        = map(string)
  default = {
    environment = "demo"
    project     = "msbuild26-ltg408"
  }
}
