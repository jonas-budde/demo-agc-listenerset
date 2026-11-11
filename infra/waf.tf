variable "enable_waf" {
  type    = bool
  default = true
}

locals {
  # One WAF policy per team, each blocking a different path so isolation is visible.
  waf_teams = { team-a = "/blocked-a", team-b = "/blocked-b", platform = "/blocked-platform" }
}

resource "azurerm_web_application_firewall_policy" "team" {
  for_each            = var.enable_waf ? local.waf_teams : {}
  name                = "waf-${var.prefix}-${each.key}"
  resource_group_name = azurerm_resource_group.this.name
  location            = var.location
  tags                = local.tags

  policy_settings {
    enabled = true
    mode    = "Prevention"
  }

  custom_rules {
    name      = "BlockPath"
    priority  = 10
    rule_type = "MatchRule"
    action    = "Block"
    match_conditions {
      match_variables {
        variable_name = "RequestUri"
      }
      operator     = "Contains"
      match_values = [each.value]
    }
  }

  managed_rules {
    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }
  }
}

# BYO AGC: every WAF policy the WebApplicationFirewallPolicy CRD references needs a securityPolicies resource on the AGC.
resource "azapi_resource" "sp_waf" {
  for_each                  = azurerm_web_application_firewall_policy.team
  type                      = "${local.agc_api}/securityPolicies@${local.agc_api_version}"
  name                      = "sp-waf-${each.key}"
  parent_id                 = azapi_resource.tc.id
  location                  = var.location
  schema_validation_enabled = false
  body = {
    properties = { wafPolicy = { id = each.value.id } }
  }
}

output "waf_policy_ids" {
  value = { for k, p in azurerm_web_application_firewall_policy.team : k => p.id }
}
