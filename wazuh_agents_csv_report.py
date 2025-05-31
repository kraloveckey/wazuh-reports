#!/usr/bin/env python3

import json
import requests
import urllib3
from base64 import b64encode
import csv

# Disable insecure https warnings (for self-signed SSL certificates)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration
WAZUH_PROTOCOL = 'https'
WAZUH_HOST = 'localhost'
WAZUH_PORT = 55000
WAZUH_USER = 'wazuh-wui'
WAZUH_PASSWORD = 'wazuh-wui'
WAZUH_LOGIN_ENDPOINT = 'security/user/authenticate'

WAZUH_LOGIN_URL = f"{WAZUH_PROTOCOL}://{WAZUH_HOST}:{WAZUH_PORT}/{WAZUH_LOGIN_ENDPOINT}"
WAZUH_BASIC_AUTH = f"{WAZUH_USER}:{WAZUH_PASSWORD}".encode()
WAZUH_LOGIN_HEADERS = {'Content-Type': 'application/json',
                 'Authorization': f'Basic {b64encode(WAZUH_BASIC_AUTH).decode()}'}

print("\nLogin request ...\n")

response = requests.post(WAZUH_LOGIN_URL, headers=WAZUH_LOGIN_HEADERS, verify=False)
token = json.loads(response.content.decode())['data']['token']
print(token)

# New authorization header with the JWT token we got
requests_headers = {'Content-Type': 'application/json',
                    'Authorization': f'Bearer {token}'}

print("\n- API calls with TOKEN environment variable ...\n")


# Headers for the API request
headers = {
    'Authorization': f'Bearer {token}',
}

# Fetching agents from Wazuh API
response = requests.get(f'{WAZUH_PROTOCOL}://{WAZUH_HOST}:{WAZUH_PORT}/agents', headers=headers, verify=False)

# Check if request was successful
if response.status_code == 200:
    data = response.json()
    agents = data['data']['affected_items']

    # Create a set of all possible keys (fields)
    all_keys = set()
    for agent in agents:
        all_keys.update(agent.keys())

    # Create CSV
    with open('wazuh_agents.csv', 'w', newline='') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=all_keys)

        writer.writeheader()

        for agent in agents:
            # Filter out the agent with ID "000"
            if agent.get('id') != '000':
                writer.writerow({key: agent.get(key, "") for key in all_keys})

else:
    print(f"Failed to retrieve agents. Status code: {response.status_code}, Error: {response.json()}")