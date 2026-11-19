#!/usr/bin/env bash
# Uploads and publishes the runbook scripts, then links the pause runbook to its schedule.
#
# Runs after the Bicep deployment because ARM can't hold runbook content, and a runbook must
# be published before a schedule can be linked to it. Safe to re-run: content is replaced and
# re-published, and the schedule link is only created when it's missing.
#
# Usage: publish-runbooks.sh <subscription-deployment-name> <runbooks-directory>
# Needs: az CLI (logged in to the target subscription) and jq.

set -euo pipefail

deployment_name="${1:?Usage: publish-runbooks.sh <deployment-name> <runbooks-directory>}"
runbooks_dir="${2:?Usage: publish-runbooks.sh <deployment-name> <runbooks-directory>}"
api_version="2024-10-23"

echo "Reading outputs of deployment '${deployment_name}'"
outputs=$(az deployment sub show --name "${deployment_name}" --query properties.outputs -o json)

output() { jq -r --arg k "$1" '.[$k].value' <<<"${outputs}"; }
resource_group=$(output resourceGroupName)
automation_account=$(output automationAccountName)
pause_runbook=$(output pauseRunbookName)
start_runbook=$(output startRunbookName)
pause_schedule=$(output pauseScheduleName)

az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null

for runbook in "${pause_runbook}" "${start_runbook}"; do
  file="${runbooks_dir}/${runbook}.ps1"
  if [[ ! -f "${file}" ]]; then
    echo "##vso[task.logissue type=error]Runbook script not found: ${file}"
    exit 1
  fi

  echo "Uploading ${file} to runbook '${runbook}'"
  az automation runbook replace-content \
    --resource-group "${resource_group}" \
    --automation-account-name "${automation_account}" \
    --name "${runbook}" \
    --content @"${file}" \
    --only-show-errors

  echo "Publishing runbook '${runbook}'"
  az automation runbook publish \
    --resource-group "${resource_group}" \
    --automation-account-name "${automation_account}" \
    --name "${runbook}" \
    --only-show-errors
done

if [[ -z "${pause_schedule}" ]]; then
  echo "No pause schedule in this environment (production runs 24/7). Done."
  exit 0
fi

subscription_id=$(az account show --query id -o tsv)
account_path="/subscriptions/${subscription_id}/resourceGroups/${resource_group}/providers/Microsoft.Automation/automationAccounts/${automation_account}"

existing=$(az rest --method get --url "${account_path}/jobSchedules?api-version=${api_version}" -o json |
  jq --arg rb "${pause_runbook}" --arg s "${pause_schedule}" \
    '[.value[] | select(.properties.runbook.name == $rb and .properties.schedule.name == $s)] | length')

if [[ "${existing}" -gt 0 ]]; then
  echo "Runbook '${pause_runbook}' is already linked to schedule '${pause_schedule}'."
else
  job_schedule_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
  echo "Linking runbook '${pause_runbook}' to schedule '${pause_schedule}'"
  az rest --method put \
    --url "${account_path}/jobSchedules/${job_schedule_id}?api-version=${api_version}" \
    --body "{\"properties\":{\"runbook\":{\"name\":\"${pause_runbook}\"},\"schedule\":{\"name\":\"${pause_schedule}\"},\"parameters\":{}}}" \
    --only-show-errors >/dev/null
fi

echo "Done."
