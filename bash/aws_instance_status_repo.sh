#!/bin/bash

# Generates a report of all EC2 instances and their status
REGION="us-east-1"
REPORT="/tmp/aws_instance_report_$(date +%F).txt"

aws ec2 describe-instances --region "$REGION" --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table > "$REPORT"
echo "EC2 instance status report saved to $REPORT"
