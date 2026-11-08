variable "location" {
  description = "The region where most of the Azure resources will be deployed."
  type        = string
  default     = "switzerlandnorth"
}

variable "resource_group_name" {
  description = "Optional name for the resource group. When null, defaults to rg-gpuprofiling<NN>."
  type        = string
  default     = null
}

variable "anyscale_cloud_location" {
  description = "The region where the Anyscale cloud resource will be deployed. Must be a region that Anyscale supports. See https://learn.microsoft.com/azure/anyscale-on-azure/supported-regions for more details."
  type        = string
  default     = "eastus"
  validation {
    condition     = contains(["westcentralus", "eastus", "eastus2", "westus2", "westus3", "southcentralus"], var.anyscale_cloud_location)
    error_message = "The location must be one of the following: westcentralus, eastus, eastus2, westus2, westus3, southcentralus."
  }
}

variable "system_node_pool_vm_count" {
  description = "The number of nodes in the system node pool in the AKS cluster. Must be a positive integer."
  type        = number
  default     = 3
  validation {
    condition     = var.system_node_pool_vm_count > 0
    error_message = "The system_node_pool_vm_count must be a positive integer."
  }
}

variable "nvidia_sku_name" {
  description = "The VM size for the gpu node pool in the AKS cluster. Must be a size that is supported in the chosen location. See https://learn.microsoft.com/azure/anyscale-on-azure/supported-regions for more details."
  type        = string
  default     = "Standard_NV72ads_A10_v5"
}

variable "anyscale_gpu_instance_type" {
  description = <<-EOT
    GPU pod shape (an Anyscale "instance type") that the Anyscale operator offers in compute configs.
    cpu and memory must fit on one nvidia_sku_name node after DaemonSet overhead, and accelerator must be
    the GPU in that SKU. The operator schedules GPU pods with the node selector
    nvidia.com/gpu.product=NVIDIA-<accelerator>, which the GPU node pool sets.
  EOT
  type = object({
    name        = string
    cpu         = number
    memory      = string
    gpus        = optional(number, 1)
    accelerator = string
  })
  default = {
    name        = "8CPU-64GB-1xA10"
    cpu         = 8
    memory      = "64Gi"
    accelerator = "A10"
  }
  validation {
    condition     = contains(["T4", "A10", "A100", "H100"], var.anyscale_gpu_instance_type.accelerator)
    error_message = "accelerator must be one of T4, A10, A100, or H100 (the GPUs the Anyscale operator maps on Azure)."
  }
}

variable "accept_anyscale_platform_agreement" {
  description = <<-EOT
    Accept the Anyscale on Azure agreement (Anyscale.Platform/agreements/default) for the subscription. It must be
    Active before an Anyscale cloud can be created with Terraform, the Azure CLI, or an ARM template (the Azure
    portal's Create flow accepts it on the Review + submit tab instead). It's accepted once per subscription.
    Setting this to true means Terraform accepts the terms on your behalf, so review them first:
    https://www.anyscale.com/anyscale-on-azure-terms. Set to false if the agreement is already Active or your
    organization accepts it out of band.
  EOT
  type        = bool
  default     = true
}

variable "pyroscope_pls_auto_approval_subscription_ids" {
  description = "Comma-separated subscription IDs whose private endpoints the Pyroscope Private Link Service auto-approves. Azure Managed Grafana creates its managed private endpoint in a Microsoft-owned platform subscription that differs by Grafana region. See the README for how to look it up."
  type        = string
  default     = "e08067a5-cca7-453a-87df-eb2ddd9d60d6"
}

variable "pyroscope_persistent_volume_size" {
  description = <<-EOT
    Size of a persistent volume for Pyroscope's profile data (an Azure Disk from the cluster's default storage class),
    for example "32Gi". The default (null) keeps the chart's emptyDir, which loses every stored profile when the
    Pyroscope pod restarts or moves, for example when Node Autoprovisioning consolidates its node. Turning this on for
    an existing deployment needs a one-time step; see the README.
  EOT
  type        = string
  default     = null
}

variable "pyroscope_do_not_disrupt" {
  description = "Add the karpenter.sh/do-not-disrupt annotation to the Pyroscope pod, so Node Autoprovisioning doesn't voluntarily move it (consolidation or drift). The node it runs on then stays until the pod is gone."
  type        = bool
  default     = false
}

variable "storage_allow_nested_items_to_be_public" {
  description = "Whether containers and blobs in the storage account can be made public (allowBlobPublicAccess). The default (true) keeps the Azure default. Anyscale reads and writes the storage with its managed identity and never needs public access, so false blocks public containers without affecting the demo."
  type        = bool
  default     = true
}
