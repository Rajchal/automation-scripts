from google.cloud import resource_manager_v3
import yaml

def deploy_gcp_config():
    client = resource_manager_v3.ProjectsClient()
    with open('gcp_deployment.yaml') as config_file:
        config = yaml.safe_load(config_file)
    
    operation = client.create_project(config)
    print(f"Waiting for operation {operation.name} to complete...")
    response = operation.result()
    print(f"Deployment completed: {response}")

if __name__ == "__main__":
    deploy_gcp_config()
