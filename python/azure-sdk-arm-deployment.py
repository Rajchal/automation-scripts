from azure.identity import DefaultAzureCredential
from azure.mgmt.resource import ResourceManagementClient
import json

def deploy_arm_template():
    credential = DefaultAzureCredential()
    subscription_id = 'your_subscription_id'
    resource_client = ResourceManagementClient(credential, subscription_id)
    
    with open('arm_template.json') as template_file:
        template = json.load(template_file)
    
    deployment_properties = {
        'mode': 'Incremental',
        'template': template,
        'parameters': {
            'parameterName': {
                'value': 'parameterValue'
            }
        }
    }
    
    deployment_async_operation = resource_client.deployments.begin_create_or_update(
        'resource_group_name',
        'deployment_name',
        deployment_properties
    )
    deployment_async_operation.result()
    print("Deployment completed")

if __name__ == "__main__":
    deploy_arm_template()
