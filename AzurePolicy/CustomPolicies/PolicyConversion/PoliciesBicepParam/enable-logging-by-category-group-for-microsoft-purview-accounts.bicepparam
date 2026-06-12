using '../main.bicep'

param policyDefinitionName = 'enable-logging-by-category-group-for-microsoft-purview-accounts'

param policydisplayName = 'Enable logging by category group for Microsoft Purview accounts (microsoft.purview/accounts) by tags to Log Analytics'

param description = 'Resource logs should be enabled to track activities and events that take place on your resources and give you visibility and insights into any changes that occur. This policy deploys a diagnostic setting using a category group to route logs to a Log Analytics workspace for Microsoft Purview accounts (microsoft.purview/accounts).'

param metadata = '''
{
  "category": "Monitoring",
  "version": "1.1.0"
}
'''

param policyParameters = '''
{
  "categoryGroup": {
    "allowedValues": [
      "audit",
      "allLogs"
    ],
    "defaultValue": "audit",
    "metadata": {
      "description": "Diagnostic category group - none, audit, or allLogs.",
      "displayName": "Category Group"
    },
    "type": "String"
  },
  "diagnosticSettingName": {
    "defaultValue": "setByPolicy-LogAnalytics",
    "metadata": {
      "description": "Diagnostic Setting Name",
      "displayName": "Diagnostic Setting Name"
    },
    "type": "String"
  },
  "effect": {
    "allowedValues": [
      "DeployIfNotExists",
      "AuditIfNotExists",
      "Disabled"
    ],
    "defaultValue": "DeployIfNotExists",
    "metadata": {
      "description": "Enable or disable the execution of the policy",
      "displayName": "Effect"
    },
    "type": "String"
  },
  "logAnalytics": {
    "metadata": {
      "assignPermissions": true,
      "description": "Log Analytics Workspace",
      "displayName": "Log Analytics Workspace",
      "strongType": "omsWorkspace"
    },
    "type": "String"
  },
  "resourceLocationList": {
    "defaultValue": [
      "*"
    ],
    "metadata": {
      "description": "Resource Location List to send logs to nearby Log Analytics. A single entry \"*\" selects all locations (default).",
      "displayName": "Resource Location List"
    },
    "type": "Array"
  },
  "tagName": {
    "type": "String",
    "metadata": {
      "description": "Name of the Tag, such as environment",
      "displayName": "Tag Name"
    }
  },
  "tagValue": {
    "type": "String",
    "metadata": {
      "description": "Value of the Tag, such as Prod",
      "displayName": "Tag Value"
    }
  }
}
'''

param policyRule = '''
{
  "if": {
    "allOf": [
      {
        "equals": "microsoft.purview/accounts",
        "field": "type"
      },
      {
        "field": "[concat('tags[', parameters('tagName'), ']')]",
        "equals": "[parameters('tagValue')]"
      },
      {
        "anyOf": [
          {
            "equals": "*",
            "value": "[first(parameters('resourceLocationList'))]"
          },
          {
            "field": "location",
            "in": "[parameters('resourceLocationList')]"
          }
        ]
      }
    ]
  },
  "then": {
    "details": {
      "deployment": {
        "properties": {
          "mode": "incremental",
          "parameters": {
            "categoryGroup": {
              "value": "[parameters('categoryGroup')]"
            },
            "diagnosticSettingName": {
              "value": "[parameters('diagnosticSettingName')]"
            },
            "logAnalytics": {
              "value": "[parameters('logAnalytics')]"
            },
            "resourceName": {
              "value": "[field('name')]"
            }
          },
          "template": {
            "$schema": "http://schema.management.azure.com/schemas/2019-08-01/deploymentTemplate.json#",
            "contentVersion": "1.0.0.0",
            "outputs": {
              "policy": {
                "type": "string",
                "value": "[concat('Diagnostic setting ', parameters('diagnosticSettingName'), ' for type Microsoft Purview accounts (microsoft.purview/accounts), resourceName ', parameters('resourceName'), ' to Log Analytics ', parameters('logAnalytics'), ' configured')]"
              }
            },
            "parameters": {
              "categoryGroup": {
                "type": "String"
              },
              "diagnosticSettingName": {
                "type": "string"
              },
              "logAnalytics": {
                "type": "string"
              },
              "resourceName": {
                "type": "string"
              }
            },
            "resources": [
              {
                "apiVersion": "2021-05-01-preview",
                "name": "[concat(parameters('resourceName'), '/', 'Microsoft.Insights/', parameters('diagnosticSettingName'))]",
                "properties": {
                  "logs": [
                    {
                      "categoryGroup": "audit",
                      "enabled": "[equals(parameters('categoryGroup'), 'audit')]"
                    },
                    {
                      "categoryGroup": "allLogs",
                      "enabled": "[equals(parameters('categoryGroup'), 'allLogs')]"
                    }
                  ],
                  "metrics": [],
                  "workspaceId": "[parameters('logAnalytics')]"
                },
                "type": "microsoft.purview/accounts/providers/diagnosticSettings"
              }
            ],
            "variables": {}
          }
        }
      },
      "evaluationDelay": "AfterProvisioning",
      "existenceCondition": {
        "allOf": [
          {
            "count": {
              "field": "Microsoft.Insights/diagnosticSettings/logs[*]",
              "where": {
                "allOf": [
                  {
                    "equals": "[equals(parameters('categoryGroup'), 'audit')]",
                    "field": "Microsoft.Insights/diagnosticSettings/logs[*].enabled"
                  },
                  {
                    "equals": "audit",
                    "field": "microsoft.insights/diagnosticSettings/logs[*].categoryGroup"
                  }
                ]
              }
            },
            "equals": 1
          },
          {
            "count": {
              "field": "Microsoft.Insights/diagnosticSettings/logs[*]",
              "where": {
                "allOf": [
                  {
                    "equals": "[equals(parameters('categoryGroup'), 'allLogs')]",
                    "field": "Microsoft.Insights/diagnosticSettings/logs[*].enabled"
                  },
                  {
                    "equals": "allLogs",
                    "field": "microsoft.insights/diagnosticSettings/logs[*].categoryGroup"
                  }
                ]
              }
            },
            "equals": 1
          },
          {
            "equals": "[parameters('logAnalytics')]",
            "field": "Microsoft.Insights/diagnosticSettings/workspaceId"
          }
        ]
      },
      "roleDefinitionIds": [
        "/providers/Microsoft.Authorization/roleDefinitions/92aaf0da-9dab-42b6-94a3-d43ce8d16293"
      ],
      "type": "Microsoft.Insights/diagnosticSettings"
    },
    "effect": "[parameters('effect')]"
  }
}
'''
