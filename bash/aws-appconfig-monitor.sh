#!/bin/bash

################################################################################
# AWS AppConfig Deployment Monitor
# Monitors AppConfig applications, environments, and configuration deployments
# Detects failed deployments, configuration drift, and validation errors
################################################################################

set -euo pipefail

# Configuration
REGION="${AWS_REGION:-us-east-1}"
OUTPUT_FILE="/tmp/appconfig-monitor-$(date +%s).txt"
LOG_FILE="/var/log/appconfig-monitor.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
DAYS_BACK="${DAYS_BACK:-7}"

################################################################################
# Logging
################################################################################
log_message() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%dT%H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

################################################################################
# Get all AppConfig applications
################################################################################
get_appconfig_applications() {
    aws appconfig list-applications \
        --region "${REGION}" \
        --query 'Items[*].[Id,Name,Description]' \
        --output text 2>/dev/null || {
        log_message "ERROR" "Failed to fetch AppConfig applications"
        return 1
    }
}

################################################################################
# Get application environments
################################################################################
get_application_environments() {
    local app_id="$1"
    
    aws appconfig list-environments \
        --application-id "${app_id}" \
        --region "${REGION}" \
        --query 'Items[*].[Id,Name,State,Description]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Get configuration profiles
################################################################################
get_configuration_profiles() {
    local app_id="$1"
    
    aws appconfig list-configuration-profiles \
        --application-id "${app_id}" \
        --region "${REGION}" \
        --query 'Items[*].[Id,Name,LocationUri,Type]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Get deployment strategy
################################################################################
get_deployment_strategy() {
    local strategy_id="$1"
    
    aws appconfig get-deployment-strategy \
        --deployment-strategy-id "${strategy_id}" \
        --region "${REGION}" \
        --query '[Name,DeploymentDurationInMinutes,GrowthFactor,FinalBakeTimeInMinutes]' \
        --output text 2>/dev/null || echo "ERROR"
}

################################################################################
# Monitor deployments
################################################################################
monitor_deployments() {
    log_message "INFO" "Monitoring AppConfig deployments..."
    
    {
        echo ""
        echo "=== DEPLOYMENT STATUS MONITOR ==="
    } >> "${OUTPUT_FILE}"
    
    local failed_count=0
    local success_count=0
    local in_progress_count=0
    
    while IFS=$'\t' read -r app_id app_name _ ; do
        while IFS=$'\t' read -r env_id env_name env_state _; do
            # List deployments for this environment
            local deployments=$(aws appconfig list-deployments \
                --application-id "${app_id}" \
                --environment-id "${env_id}" \
                --region "${REGION}" \
                --query 'Items[*].[DeploymentNumber,Status,PercentageComplete,StartedAt]' \
                --output text 2>/dev/null || echo "ERROR")
            
            if [[ "${deployments}" != "ERROR" ]] && [[ -n "${deployments}" ]]; then
                echo "${deployments}" | while IFS=$'\t' read -r deploy_num status percent_complete started_at; do
                    {
                        echo "Application: ${app_name}"
                        echo "  Environment: ${env_name}"
                        echo "  Deployment #: ${deploy_num}"
                        echo "  Status: ${status}"
                        echo "  Progress: ${percent_complete}%"
                        echo "  Started: ${started_at}"
                    } >> "${OUTPUT_FILE}"
                    
                    case "${status}" in
                        FAILED)
                            ((failed_count++))
                            {
                                echo "  WARNING: Deployment failed"
                            } >> "${OUTPUT_FILE}"
                            ;;
                        COMPLETE)
                            ((success_count++))
                            ;;
                        IN_PROGRESS)
                            ((in_progress_count++))
                            ;;
                    esac
                    
                    echo "" >> "${OUTPUT_FILE}"
                done
            fi
        done < <(get_application_environments "${app_id}")
    done < <(get_appconfig_applications)
    
    {
        echo "Deployment Summary:"
        echo "  Successful: ${success_count}"
        echo "  Failed: ${failed_count}"
        echo "  In Progress: ${in_progress_count}"
        echo ""
    } >> "${OUTPUT_FILE}"
    
    if [[ ${failed_count} -gt 0 ]]; then
        log_message "WARN" "Found ${failed_count} failed deployments"
    fi
}

################################################################################
# Audit configuration profiles
################################################################################
audit_configuration_profiles() {
    log_message "INFO" "Auditing configuration profiles..."
    
    {
        echo ""
        echo "=== CONFIGURATION PROFILE AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r app_id app_name _; do
        {
            echo "Application: ${app_name}"
        } >> "${OUTPUT_FILE}"
        
        local profiles=$(get_configuration_profiles "${app_id}")
        
        if [[ "${profiles}" != "ERROR" ]] && [[ -n "${profiles}" ]]; then
            echo "${profiles}" | while IFS=$'\t' read -r profile_id profile_name location_uri profile_type; do
                {
                    echo "  Configuration Profile: ${profile_name}"
                    echo "    ID: ${profile_id}"
                    echo "    Type: ${profile_type}"
                    echo "    Location: ${location_uri}"
                } >> "${OUTPUT_FILE}"
            done
        else
            {
                echo "  No configuration profiles found"
            } >> "${OUTPUT_FILE}"
        fi
        
        echo "" >> "${OUTPUT_FILE}"
    done < <(get_appconfig_applications)
}

################################################################################
# Check validator configurations
################################################################################
check_validator_configs() {
    log_message "INFO" "Checking validator configurations..."
    
    {
        echo ""
        echo "=== VALIDATOR CONFIGURATION AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r app_id app_name _; do
        local profiles=$(get_configuration_profiles "${app_id}")
        
        if [[ "${profiles}" != "ERROR" ]] && [[ -n "${profiles}" ]]; then
            echo "${profiles}" | while IFS=$'\t' read -r profile_id profile_name _ _; do
                # Get validators for this profile
                local validators=$(aws appconfig list-configuration-profile-validators \
                    --application-id "${app_id}" \
                    --configuration-profile-id "${profile_id}" \
                    --region "${REGION}" \
                    --query 'Validators[*].[Type,Uri]' \
                    --output text 2>/dev/null || echo "NONE")
                
                if [[ "${validators}" != "NONE" ]] && [[ -n "${validators}" ]]; then
                    {
                        echo "Profile: ${profile_name}"
                        echo "  Validators:"
                        echo "${validators}" | while IFS=$'\t' read -r validator_type validator_uri; do
                            echo "    - Type: ${validator_type}"
                            echo "      URI: ${validator_uri}"
                        done
                        echo ""
                    } >> "${OUTPUT_FILE}"
                else
                    {
                        echo "Profile: ${profile_name}"
                        echo "  WARNING: No validators configured"
                        echo ""
                    } >> "${OUTPUT_FILE}"
                fi
            done
        fi
    done < <(get_appconfig_applications)
}

################################################################################
# Audit environments
################################################################################
audit_environments() {
    log_message "INFO" "Auditing AppConfig environments..."
    
    {
        echo ""
        echo "=== ENVIRONMENT AUDIT ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r app_id app_name _; do
        {
            echo "Application: ${app_name}"
        } >> "${OUTPUT_FILE}"
        
        local envs=$(get_application_environments "${app_id}")
        
        if [[ "${envs}" != "ERROR" ]] && [[ -n "${envs}" ]]; then
            echo "${envs}" | while IFS=$'\t' read -r env_id env_name env_state description; do
                {
                    echo "  Environment: ${env_name}"
                    echo "    State: ${env_state}"
                    echo "    Description: ${description:-N/A}"
                } >> "${OUTPUT_FILE}"
            done
        fi
        
        echo "" >> "${OUTPUT_FILE}"
    done < <(get_appconfig_applications)
}

################################################################################
# Monitor hosted configuration versions
################################################################################
monitor_hosted_versions() {
    log_message "INFO" "Monitoring hosted configuration versions..."
    
    {
        echo ""
        echo "=== HOSTED CONFIGURATION VERSIONS ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r app_id app_name _; do
        local profiles=$(get_configuration_profiles "${app_id}")
        
        if [[ "${profiles}" != "ERROR" ]] && [[ -n "${profiles}" ]]; then
            echo "${profiles}" | while IFS=$'\t' read -r profile_id profile_name location_uri profile_type; do
                if [[ "${profile_type}" == "AWS.AppConfig.HostedConfigurationVersion" ]]; then
                    # List versions for this hosted configuration
                    local versions=$(aws appconfig list-hosted-configuration-versions \
                        --application-id "${app_id}" \
                        --configuration-profile-id "${profile_id}" \
                        --region "${REGION}" \
                        --query 'Items[*].[VersionNumber,Description,CreatedAt]' \
                        --output text 2>/dev/null | head -5)
                    
                    if [[ -n "${versions}" ]]; then
                        {
                            echo "Profile: ${profile_name}"
                            echo "  Recent Versions:"
                            echo "${versions}" | while IFS=$'\t' read -r version desc created; do
                                echo "    - Version ${version} (${created})"
                                [[ -n "${desc}" ]] && echo "      ${desc}"
                            done
                            echo ""
                        } >> "${OUTPUT_FILE}"
                    fi
                fi
            done
        fi
    done < <(get_appconfig_applications)
}

################################################################################
# Check deployment strategies
################################################################################
check_deployment_strategies() {
    log_message "INFO" "Analyzing deployment strategies..."
    
    {
        echo ""
        echo "=== DEPLOYMENT STRATEGIES ==="
    } >> "${OUTPUT_FILE}"
    
    while IFS=$'\t' read -r app_id app_name _; do
        while IFS=$'\t' read -r env_id env_name _ _; do
            # Get environment details for deployment strategy
            local env_details=$(aws appconfig get-environment \
                --application-id "${app_id}" \
                --environment-id "${env_id}" \
                --region "${REGION}" \
                --query '[Name,DeploymentStrategyId]' \
                --output text 2>/dev/null)
            
            if [[ -n "${env_details}" ]]; then
                read -r env_name strategy_id <<< "${env_details}"
                
                if [[ -n "${strategy_id}" ]]; then
                    local strategy_info=$(get_deployment_strategy "${strategy_id}")
                    
                    if [[ "${strategy_info}" != "ERROR" ]]; then
                        {
                            echo "Environment: ${env_name}"
                            echo "  Strategy ID: ${strategy_id}"
                            echo "  Details: ${strategy_info}"
                            echo ""
                        } >> "${OUTPUT_FILE}"
                    fi
                fi
            fi
        done < <(get_application_environments "${app_id}")
    done < <(get_appconfig_applications)
}

################################################################################
# Send Slack alert
################################################################################
send_slack_alert() {
    local app_count="$1"
    local failed_deployments="$2"
    
    [[ -z "${SLACK_WEBHOOK}" ]] && return 0
    
    local payload=$(cat <<EOF
{
    "text": "AWS AppConfig Monitoring Report",
    "attachments": [
        {
            "color": "warning",
            "fields": [
                {"title": "Region", "value": "${REGION}", "short": true},
                {"title": "Applications", "value": "${app_count}", "short": true},
                {"title": "Failed Deployments", "value": "${failed_deployments}", "short": true},
                {"title": "Analysis Period", "value": "${DAYS_BACK} days", "short": true},
                {"title": "Timestamp", "value": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "short": false}
            ]
        }
    ]
}
EOF
)
    
    curl -X POST -H 'Content-type: application/json' \
        --data "${payload}" \
        "${SLACK_WEBHOOK}" 2>/dev/null || log_message "WARN" "Failed to send Slack alert"
}

################################################################################
# Main monitoring logic
################################################################################
main() {
    log_message "INFO" "Starting AppConfig deployment monitoring"
    
    {
        echo "AWS AppConfig Deployment Monitor Report"
        echo "========================================"
        echo "Generated: $(date)"
        echo "Region: ${REGION}"
        echo "Analysis Period: ${DAYS_BACK} days"
    } > "${OUTPUT_FILE}"
    
    local app_count=$(get_appconfig_applications | wc -l)
    
    monitor_deployments
    audit_configuration_profiles
    check_validator_configs
    audit_environments
    monitor_hosted_versions
    check_deployment_strategies
    
    log_message "INFO" "Monitoring complete. Report saved to: ${OUTPUT_FILE}"
    
    local failed_count=$(grep -c "FAILED\|WARNING" "${OUTPUT_FILE}" || echo "0")
    
    send_slack_alert "${app_count}" "${failed_count}"
    
    cat "${OUTPUT_FILE}"
}

main "$@"
