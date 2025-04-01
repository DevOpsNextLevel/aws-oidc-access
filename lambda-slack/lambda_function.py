import boto3
import csv
import os
import json
import urllib.parse
import requests

# Initialize AWS clients
s3 = boto3.client('s3')
identitystore = boto3.client('identitystore')

# Configuration values (update as needed)
IDENTITY_STORE_ID = 'd-9067d1167c'  # Your Identity Store ID
GROUP_ID = '645864e8-2041-7088-69b0-7517e985e781'  # Your Group ID
SLACK_WEBHOOK_URL = os.environ['SLACK_WEBHOOK_URL']

def send_slack_notification(message):
    try:
        response = requests.post(SLACK_WEBHOOK_URL, json={"text": message})
        print(f"Slack response: {response.status_code}, {response.text}")
    except Exception as e:
        print(f"Slack notification failed: {e}")

def user_exists(username):
    """
    Check if a user exists in Identity Store using the UserName filter.
    The username is normalized to lower-case to avoid mismatches.
    """
    try:
        normalized_username = username.lower()
        print(f"Checking existence for user: {normalized_username}")
        response = identitystore.list_users(
            IdentityStoreId=IDENTITY_STORE_ID,
            Filters=[
                {
                    'AttributePath': 'UserName',
                    'AttributeValue': normalized_username
                }
            ]
        )
        users = response.get('Users', [])
        print(f"Found {len(users)} users for {normalized_username}")
        return len(users) > 0
    except Exception as e:
        print(f"Error checking user existence: {e}")
        return False

def lambda_handler(event, context):
    print("Event received:", json.dumps(event))
    created_users = []
    skipped_users = []
    
    try:
        # Extract bucket and key from S3 event
        bucket = event['Records'][0]['s3']['bucket']['name']
        key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'])
        
        # Retrieve and parse CSV from S3
        response = s3.get_object(Bucket=bucket, Key=key)
        csv_content = response['Body'].read().decode('utf-8').splitlines()
        reader = csv.DictReader(csv_content)
        
        for row in reader:
            # Extract and normalize required fields
            username = row.get('Username', '').strip().lower()
            first_name = row.get('FirstName', '').strip()
            last_name = row.get('LastName', '').strip()
            email = row.get('Email', '').strip()
            
            # Skip rows with missing data
            if not all([username, first_name, last_name, email]):
                print(f"Skipping row with missing data: {row}")
                continue
            
            # Check if user exists by username
            if user_exists(username):
                print(f"User {username} already exists. Skipping.")
                skipped_users.append(username)
                continue
            
            print(f"Creating user {username} ({email})...")
            # Create the user in Identity Store
            user_response = identitystore.create_user(
                IdentityStoreId=IDENTITY_STORE_ID,
                UserName=username,
                DisplayName=f"{first_name} {last_name}",
                Name={
                    'GivenName': first_name,
                    'FamilyName': last_name
                },
                Emails=[{
                    'Value': email,
                    'Type': 'work',
                    'Primary': True
                }]
            )
            user_id = user_response['UserId']
            
            # Add the user to the specified group
            identitystore.create_group_membership(
                IdentityStoreId=IDENTITY_STORE_ID,
                GroupId=GROUP_ID,
                MemberId={'UserId': user_id}
            )
            
            created_users.append(username)
        
        summary = f"Lambda User Sync Completed\nCreated: {created_users}\nSkipped: {skipped_users}"
        print(summary)
        send_slack_notification(summary)
        return {"statusCode": 200, "body": summary}
    
    except Exception as e:
        error_msg = f"Lambda error: {str(e)}"
        print(error_msg)
        send_slack_notification(error_msg)
        return {"statusCode": 500, "body": error_msg}
