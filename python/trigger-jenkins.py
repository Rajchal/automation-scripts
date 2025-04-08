from jenkinsapi.jenkins import Jenkins

def trigger_jenkins_job():
    jenkins_url = 'http://your-jenkins-url:8080'
    server = Jenkins(jenkins_url, username='your_user', password='your_password')
    
    job_name = 'your_job'
    job = server.get_job(job_name)
    job.invoke(build_params={'param1': 'value1'})
    
    print(f"Triggered job: {job_name}")

if __name__ == "__main__":
    trigger_jenkins_job()
