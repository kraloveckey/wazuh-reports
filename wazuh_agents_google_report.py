#!/usr/bin/env python3
import json
import requests
import urllib3
import csv
import os
from base64 import b64encode

# Disable insecure https warnings (for self-signed SSL certificates)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


# ====================================================================
# Google Drive & Sheets API Imports
# ====================================================================
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload
from googleapiclient.errors import HttpError # For handling Google Sheets API errors


# ====================================================================
# Wazuh API Configuration
# ====================================================================
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


# ====================================================================
# Google Drive / Sheets Configuration
# ====================================================================

# Path to the JSON file of the Service Account key. Get this file from Google Cloud Console
SERVICE_ACCOUNT_FILE = '/PATH/TO/FILE/credentials.json' # <--- CHANGE THIS LINE IF THE FILE HAS A DIFFERENT NAME OR PATH

# Permissions (variable SCOPES) for Google Drive and Google Sheets API
# 'https://www.googleapis.com/auth/drive' allows to upload files
# 'https://www.googleapis.com/auth/spreadsheets' allows to format Google Sheets
SCOPES = ['https://www.googleapis.com/auth/drive', 'https://www.googleapis.com/auth/spreadsheets']

# Folder ID of the Google Drive folder where to upload the file.
# Find it in the URL of the folder on Google Drive (for example, drive.google.com/drive/folders/YOUR_ID_FOLDER)
FOLDER_ID = '1wz3uDG3yDMTokVkqB7k0oZKgDD5mz5lF' # <--- CHANGE THIS LINE TO 'YOUR_ID_FOLDER'

# The name of the temporary CSV file that will be created locally.
CSV_FILE_NAME = 'wazuh_agents.csv'

# The name under which Google Sheet will be on Google Drive.
GOOGLE_SHEET_NAME = 'Wazuh Agents'


# ====================================================================
# SELECTING AND ORDERING COLUMNS FOR EXPORT
# ====================================================================

# Enter here the names of the columns to be displayed in the CSV/Google Sheet, in the desired order
# Make sure that the names exactly match the keys in the data returned by the Wazuh API
WAZUH_DESIRED_COLUMNS = [
    ('id', 'Agent ID'),
    ('name', 'Agent Name'),
    ('group', 'Agent Group'),
    ('ip', 'IP Address'),
    ('version', 'Agent Version'),
    ('os.name', 'OS Name'),
    ('os.version', 'OS Version'),
    ('status', 'Status'),
    ('lastKeepAlive', 'Last Activity'),
    ('disconnection_time', 'Disconnection Time'),
    ('dateAdd', 'Added Date')
    # Add or remove columns according to specific needs
]


# ====================================================================
# MAIN SCRIPT
# ====================================================================
print("\nLogin request to Wazuh API...\n")
try:
    # Step 1: Getting data from the Wazuh API
    response = requests.post(WAZUH_LOGIN_URL, headers=WAZUH_LOGIN_HEADERS, verify=False)
    response.raise_for_status() # Throws HTTPError if response status is 4xx or 5xx
    token = json.loads(response.content.decode())['data']['token']
    print(f"Wazuh API token successfully received.")

    headers = {'Authorization': f'Bearer {token}'}
    print("\nFetching agents from Wazuh API...\n")
    response = requests.get(f'{WAZUH_PROTOCOL}://{WAZUH_HOST}:{WAZUH_PORT}/agents', headers=headers, verify=False)
    response.raise_for_status() # Checking for HTTP errors

    data = response.json()
    agents = data['data']['affected_items']

    # Step 2: Create a local CSV file with selected columns
    print(f"Creating CSV file '{CSV_FILE_NAME}'...")
    with open(CSV_FILE_NAME, 'w', newline='', encoding='utf-8') as csvfile:
        # Creating a list of headers for the CSV: these will be the new column names
        csv_headers = []
        for col_def in WAZUH_DESIRED_COLUMNS:
            if isinstance(col_def, tuple):
                csv_headers.append(col_def[1]) # Take the second part of the array (WAZUH_DESIRED_COLUMNS) as the header
            else:
                csv_headers.append(col_def) # If it's (WAZUH_DESIRED_COLUMNS) just a string, use it as the title

        writer = csv.DictWriter(csvfile, fieldnames=csv_headers)
        writer.writeheader()

        for agent in agents:
            # Filter agents (ID "000")
            if agent.get('id') != '000':
                row_to_write = {}
                for col_def in WAZUH_DESIRED_COLUMNS:
                    # Determine the original key from the API and the desired column name
                    if isinstance(col_def, tuple):
                        api_key = col_def[0]
                        display_name = col_def[1]
                    else:
                        api_key = col_def
                        display_name = col_def

                    # Handling nested keys (for example, 'os.name')
                    if '.' in api_key:
                        keys = api_key.split('.')
                        value = agent
                        found = True
                        for key_part in keys:
                            if isinstance(value, dict) and key_part in value:
                                value = value.get(key_part)
                            else:
                                value = "" # If the nested key is missing
                                found = False
                                break
                        row_to_write[display_name] = str(value) if found else ""
                    else:
                        row_to_write[display_name] = str(agent.get(api_key, ""))
                writer.writerow(row_to_write)
    print(f"\nCSV file '{CSV_FILE_NAME}' successfully created with selected columns...\n")

    # Step 3: Upload CSV to Google Drive in Google Sheet format
    print(f"Connecting to Google Drive/Sheets API for '{GOOGLE_SHEET_NAME}'...")
    creds = service_account.Credentials.from_service_account_file(
        SERVICE_ACCOUNT_FILE, scopes=SCOPES)

    drive_service = build('drive', 'v3', credentials=creds) # Service for working with Google Drive
    sheets_service = build('sheets', 'v4', credentials=creds) # Service for working with Google Sheets

    file_metadata = {
        'name': GOOGLE_SHEET_NAME,
        'mimeType': 'application/vnd.google-apps.spreadsheet' # Specify that it will be Google Sheet
    }
    if FOLDER_ID:
        file_metadata['parents'] = [FOLDER_ID]

    media = MediaFileUpload(CSV_FILE_NAME, mimetype='text/csv', resumable=True)

    spreadsheet_id = None # Variable for storing Google Sheet IDs

    # Create a query to search for an existing Google Sheet
    query = (
        f"name='{GOOGLE_SHEET_NAME}' and "
        f"mimeType='application/vnd.google-apps.spreadsheet' and "
        f"'{FOLDER_ID}' in parents and trashed=false"
        if FOLDER_ID else
        f"name='{GOOGLE_SHEET_NAME}' and "
        f"mimeType='application/vnd.google-apps.spreadsheet' and "
        f"'root' in parents and trashed=false"
    )

    file_list = drive_service.files().list(
        q=query,
        spaces='drive',
        fields='files(id, name)',
        supportsAllDrives=True,
        includeItemsFromAllDrives=True
    ).execute()

    existing_files = file_list.get('files', [])

    if existing_files:
        # If the file exists, update it
        file_id = existing_files[0]['id']
        drive_service.files().update(
            fileId=file_id,
            media_body=media,
            supportsAllDrives=True
        ).execute()
        spreadsheet_id = file_id
        print(f"\nGoogle Sheet '{GOOGLE_SHEET_NAME}' successfully updated to Google Drive (ID: {spreadsheet_id})...\n")
    else:
        # If the file does not exist, create a new one
        file = drive_service.files().create(body=file_metadata, media_body=media, fields='id, name', supportsAllDrives=True).execute()
        spreadsheet_id = file['id']
        print(f"Google Sheet '{GOOGLE_SHEET_NAME}' successfully created on the Google Drive (ID: {spreadsheet_id}).")

    # Step 4: Automatically adjust column widths in Google Sheet
    if spreadsheet_id:
        try:
            print(f"Adjust the column width for Google Sheet '{GOOGLE_SHEET_NAME}'...")
            # Get the ID of the first sheet in the table
            sheet_properties = sheets_service.spreadsheets().get(
                spreadsheetId=spreadsheet_id, fields='sheets.properties').execute()
            sheet_id = sheet_properties['sheets'][0]['properties']['sheetId'] if sheet_properties['sheets'] else 0

            # Create a request to automatically resize columns
            requests_body = {
                'requests': [{
                    'autoResizeDimensions': {
                        'dimensions': {
                            'sheetId': sheet_id,
                            'dimension': 'COLUMNS',
                            'startIndex': 0, # Start with the first column
                            'endIndex': len(WAZUH_DESIRED_COLUMNS) # Up to the number of desired columns
                        }
                    }
                }]
            }
            sheets_service.spreadsheets().batchUpdate(
                spreadsheetId=spreadsheet_id, body=requests_body).execute()
            print(f"\nGoogle Sheet '{GOOGLE_SHEET_NAME}' column widths are automatically adjusted...\n")
        except HttpError as err:
            print(f"Error setting column width of Google Sheet: {err}")
        except Exception as err:
            print(f"Common error when adjusting the column width of Google Sheet: {err}")

except requests.exceptions.RequestException as e:
    print(f"Error connecting to Wazuh API or receiving data: {e}")
except json.JSONDecodeError:
    print("JSON decoding error from Wazuh API response. The response may be invalid.")
except KeyError:
    print("Unable to find expected data (token or agents) in Wazuh API response.")
except FileNotFoundError:
    print(f"Error: Service Account file '{SERVICE_ACCOUNT_FILE}' not found.")
except Exception as e:
    print(f"An unexpected error occurred: {e}")

finally:
    # Cleaning up: delete a temporary CSV file
    if os.path.exists(CSV_FILE_NAME):
        os.remove(CSV_FILE_NAME)
        print(f"Temporary file '{CSV_FILE_NAME}' deleted.")

