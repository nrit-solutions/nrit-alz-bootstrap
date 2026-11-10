# A failed execution covers crashes, registration failures and stalled runners; a scaler that starts no runner is not seen.
locals {
  runner_failure_alert_enabled = local.use_private_networking && var.runner_compute_type == "azure_container_app" && var.amba_action_group_email != null
}

resource "azurerm_monitor_action_group" "runner_alerts" {
  count               = local.runner_failure_alert_enabled ? 1 : 0
  name                = "ag-runner-alerts-${var.location_short}"
  resource_group_name = azurerm_resource_group.runners[0].name
  short_name          = "runners"
  tags                = var.tags

  email_receiver {
    name                    = "platform"
    email_address           = var.amba_action_group_email
    use_common_alert_schema = true
  }
}

resource "azurerm_monitor_metric_alert" "runner_failed_executions" {
  count               = local.runner_failure_alert_enabled ? 1 : 0
  name                = "alert-runner-failed-executions-${var.location_short}"
  resource_group_name = azurerm_resource_group.runners[0].name
  scopes              = [module.runners[0].job_resource_id]
  description         = "A self-hosted runner execution failed after its retries. Jobs may be stuck in the queue. Check the executions of the runner Container Apps job."
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT1H"
  tags                = var.tags

  criteria {
    metric_namespace = "Microsoft.App/jobs"
    metric_name      = "Executions"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 0

    dimension {
      name     = "state"
      operator = "Include"
      values   = ["Failed"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.runner_alerts[0].id
  }
}
