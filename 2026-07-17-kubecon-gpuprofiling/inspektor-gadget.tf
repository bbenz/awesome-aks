resource "azurerm_kubernetes_cluster_extension" "ig_operator" {
  name           = "inspektor-gadget"
  cluster_id     = azapi_resource.aks.id
  extension_type = "microsoft.inspektorgadget"
  release_train  = "preview"

  configuration_settings = {
    "gpuObservability.enabled" = "true"
    "azureMonitor.enabled"     = "true"

    # The gadget DaemonSet tolerates all taints, so it also targets the AKS-managed
    # hosted system nodes (agent pool "hostedpool", aks-hostedpool-*), where the managed
    # admission policy aks-managed-restrict-hosted-vm-node-pinning rejects its pods.
    # The DaemonSet then never becomes ready and the extension install times out.
    "inspektor-gadget.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key"       = "kubernetes.azure.com/agentpool"
    "inspektor-gadget.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator"  = "NotIn"
    "inspektor-gadget.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].values[0]" = "hostedpool"
  }

  depends_on = [
    azapi_update_resource.aks_ds_ns_exclusion,
    azurerm_monitor_data_collection_rule_association.dcr1,
    azurerm_monitor_data_collection_rule_association.dcr2,
    azurerm_monitor_data_collection_rule_association.msci
  ]
}