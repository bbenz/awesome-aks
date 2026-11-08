locals {
  anyscale_agreement_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Anyscale.Platform/agreements/default"
}

# Accept the Anyscale on Azure agreement once per subscription. PUT is idempotent, and this
# resource action never revokes the agreement on destroy.
resource "azapi_resource_action" "anyscale_agreement_accept" {
  count       = var.accept_anyscale_platform_agreement ? 1 : 0
  type        = "Anyscale.Platform/agreements@2026-09-01"
  resource_id = local.anyscale_agreement_id
  method      = "PUT"
  body = {
    properties = {}
  }
}

# Acceptance isn't immediately consistent.
resource "time_sleep" "wait_for_anyscale_agreement" {
  count           = var.accept_anyscale_platform_agreement ? 1 : 0
  create_duration = "30s"

  depends_on = [
    azapi_resource_action.anyscale_agreement_accept
  ]
}

data "azapi_resource" "anyscale_agreement" {
  type                   = "Anyscale.Platform/agreements@2026-09-01"
  resource_id            = local.anyscale_agreement_id
  response_export_values = ["properties.status"]

  depends_on = [
    time_sleep.wait_for_anyscale_agreement
  ]
}

resource "azapi_resource" "anyscale_cloud" {
  type      = "Anyscale.Platform/clouds@2026-09-01"
  parent_id = azurerm_resource_group.example.id
  location  = var.anyscale_cloud_location
  name      = local.random_name

  // this required when azapi local schema check isn't aware of the latest api version
  schema_validation_enabled = false

  body = {
    properties = {
      acrResourceId = azurerm_container_registry.example.id
    }
  }

  tags = {
    "anyscale-cloud" = local.random_name
  }

  response_export_values = [
    "properties.ssoUrl",
    "properties.cloudResourceId"
  ]

  lifecycle {
    precondition {
      condition     = data.azapi_resource.anyscale_agreement.output.properties.status == "Active"
      error_message = "The Anyscale on Azure agreement for this subscription isn't Active. Set accept_anyscale_platform_agreement = true, or accept it first with: az rest --method PUT --url \"https://management.azure.com${local.anyscale_agreement_id}?api-version=2026-09-01\" --body '{\"properties\":{}}'"
    }
  }

  depends_on = [
    azapi_resource.aks,
    data.azapi_resource.anyscale_agreement
  ]
}

resource "azurerm_role_assignment" "anyscale_platform_contributor" {
  principal_id         = data.azurerm_client_config.current.object_id
  role_definition_name = "Anyscale Platform Contributor Role"
  scope                = azapi_resource.anyscale_cloud.id
}

resource "azapi_resource" "anyscale_cloud_resource" {
  type      = "Anyscale.Platform/clouds/cloudResources@2026-09-01"
  parent_id = azapi_resource.anyscale_cloud.id
  location  = var.anyscale_cloud_location
  name      = "default"

  // this required when azapi local schema check isn't aware of the latest api version
  schema_validation_enabled = false

  body = {
    properties = {
      provider     = "Azure"
      computeStack = "K8S"
      # No trailing slash: Anyscale derives the storage account name from this endpoint. Anyscale's
      # AKS Automatic Terraform example reports that with the slash, job logs never reach the bucket.
      cloudStorageBucketEndpoint  = trimsuffix(azurerm_storage_account.example.primary_blob_endpoint, "/")
      cloudStorageBucketName      = "abfss://${azurerm_storage_container.example.name}@${azurerm_storage_account.example.primary_dfs_host}"
      anyscaleOperatorIamIdentity = azurerm_user_assigned_identity.example.principal_id
    }
  }

  tags = {
    "anyscale-cloud" = local.random_name
  }

  response_export_values = [
    "properties.cloudResourceId"
  ]

  lifecycle {
    # The Anyscale RP rejects field updates on an existing cloud resource (400 FailedPrecondition),
    # so clouds created before the endpoint fix above keep the endpoint they were created with.
    ignore_changes = [
      body.properties.cloudStorageBucketEndpoint
    ]
  }

  depends_on = [
    azapi_resource.aks
  ]
}

resource "local_file" "anyscale_gateway" {
  filename = "anyscale-gateway.yaml"
  content = templatefile("anyscale-gateway.tmpl",
    {
      ANYSCALE_CLOUD_RESOURCE_ID = replace(azapi_resource.anyscale_cloud_resource.output.properties.cloudResourceId, "_", "-")
    }
  )
}

locals {
  ANYSCALE_CLOUD_RESOURCE_ID = replace(azapi_resource.anyscale_cloud_resource.output.properties.cloudResourceId, "_", "-")

  anyscale_gpu_instance_type_prefix = "workloads.instanceTypes.additional.${var.anyscale_gpu_instance_type.name}.resources"
}

resource "azurerm_kubernetes_cluster_extension" "anyscale_operator" {
  name           = "anyscaleoperator"
  cluster_id     = azapi_resource.aks.id
  extension_type = "Anyscale.AKS.Operator"
  release_train  = "stable"

  plan {
    name      = "anyscale-operator"
    product   = "anyscale-operator-aks"
    publisher = "anyscale1750870039553"
  }

  configuration_settings = {
    "global.auth.audience"          = "api://086bc555-6989-4362-ba30-fded273e432b/.default"
    "global.auth.iamIdentity"       = azurerm_user_assigned_identity.example.client_id
    "global.cloudDeploymentId"      = azapi_resource.anyscale_cloud_resource.output.properties.cloudResourceId
    "global.controlPlaneURL"        = "https://console.azure.anyscale.com"
    "operator.serviceAccount.name"  = "anyscale-operator"
    "workloads.serviceAccount.name" = "anyscale-operator"
    "networking.gateway.enabled"    = "true"
    "networking.gateway.name"       = "gateway"
    "networking.gateway.className"  = "approuting-istio"
    "networking.gateway.namespace"  = "anyscale-operator"
    "networking.gateway.apiVersion" = "gateway.networking.k8s.io/v1"
    "networking.gateway.hostname"   = "${replace(azapi_resource.anyscale_cloud_resource.output.properties.cloudResourceId, "_", "-")}.${azapi_resource.aks.location}.cloudapp.azure.com"

    # Tolerate the system pool's CriticalAddonsOnly taint so the Helm pre-install
    # validation hook (and the operator) schedule onto an already-running system
    # node instead of cold-provisioning a new NAP node. Without this, node
    # provisioning can exceed the extension's Helm pre-install timeout and ARM
    # reports ExtensionOperationFailed even though the operator deploys fine.
    "operator.tolerations[0].key"      = "CriticalAddonsOnly"
    "operator.tolerations[0].operator" = "Exists"
    "operator.tolerations[0].effect"   = "NoSchedule"

    # Ray GPU pods must tolerate the nvidia NodePool's nvidia.com/gpu taint, and need an
    # instance type that fits one GPU node (the chart's only T4 default is 8 CPU / 32 GiB).
    "workloads.accelerator.tolerations.default[0].key"           = "node.anyscale.com/accelerator-type"
    "workloads.accelerator.tolerations.default[0].value"         = "GPU"
    "workloads.accelerator.tolerations.default[0].effect"        = "NoSchedule"
    "workloads.accelerator.tolerations.default[1].key"           = "nvidia.com/gpu"
    "workloads.accelerator.tolerations.default[1].operator"      = "Exists"
    "workloads.accelerator.tolerations.default[1].effect"        = "NoSchedule"
    "${local.anyscale_gpu_instance_type_prefix}.CPU"             = tostring(var.anyscale_gpu_instance_type.cpu)
    "${local.anyscale_gpu_instance_type_prefix}.GPU"             = tostring(var.anyscale_gpu_instance_type.gpus)
    "${local.anyscale_gpu_instance_type_prefix}.memory"          = var.anyscale_gpu_instance_type.memory
    "${local.anyscale_gpu_instance_type_prefix}.accelerators[0]" = var.anyscale_gpu_instance_type.accelerator
  }

  depends_on = [
    azurerm_federated_identity_credential.example
  ]
}
