from python_terraform import Terraform

def apply_terraform():
    tf = Terraform(working_dir='/path/to/terraform/configs')
    tf.init()
    tf.plan()
    tf.apply(skip_plan=True)

if __name__ == "__main__":
    apply_terraform()
