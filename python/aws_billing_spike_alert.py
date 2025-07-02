import boto3
import requests
import datetime

# Config
SLACK_WEBHOOK_URL = 'https://hooks.slack.com/services/your/webhook/url'
THRESHOLD_MULTIPLIER = 2.0  # Alert if bill is 2x average

def get_cost_for_date(date):
    ce = boto3.client('ce')
    result = ce.get_cost_and_usage(
        TimePeriod={'Start': date, 'End': date},
        Granularity='DAILY',
        Metrics=['UnblendedCost']
    )
    cost = float(result['ResultsByTime'][0]['Total']['UnblendedCost']['Amount'])
    return cost

def main():
    today = datetime.date.today()
    dates = [(today - datetime.timedelta(days=i)).strftime('%Y-%m-%d') for i in range(1, 8)]
    costs = [get_cost_for_date(d) for d in dates]
    avg = sum(costs) / len(costs)
    today_cost = get_cost_for_date(today.strftime('%Y-%m-%d'))

    if today_cost > THRESHOLD_MULTIPLIER * avg:
        msg = f":rotating_light: *AWS Billing Spike Detected!* Today's cost: ${today_cost:.2f} (avg: ${avg:.2f})"
        requests.post(SLACK_WEBHOOK_URL, json={"text": msg})

if __name__ == '__main__':
    main()
