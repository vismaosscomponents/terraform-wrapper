#!/usr/bin/env python
#

import sys
import boto3
import requests
import getpass
import configparser
import base64
import xml.etree.ElementTree as ET
import re
import os
import argparse
from bs4 import BeautifulSoup
#import logging
#logging.basicConfig(level=logging.DEBUG)

# Variables
profile_output = 'json'
sslverification = True
idpentryurl = 'https://federation.visma.com/adfs/ls/idpinitiatedsignon.aspx?loginToRp=urn:amazon:webservices'
tokenDuration = 60*60
credentials_path = os.path.join(os.path.expanduser("~"), ".aws", "credentials")
config_path = os.path.join(os.path.expanduser("~"), ".aws", "config")
pumaws_configpath = os.path.join(os.path.expanduser("~"), ".pum-aws")

parser = argparse.ArgumentParser(description="Get temporary AWS credentials using Visma federated access with privileged users.")
parser.add_argument("-p", "--profile", default="default", help="Store credentials for a non-default AWS profile (default: override default credentials)")
parser.add_argument("-a", "--account", help="Filter roles for the given AWS account")
parser.add_argument("-r", "--region", help="Configure profile for the specified AWS region (default: eu-west-1)", default="eu-west-1")

args = parser.parse_args()

section=args.profile
account=args.account
profile_region = args.region

# Read last used user name
pumaws_config = configparser.RawConfigParser()
pumaws_config.read(pumaws_configpath)
lastuser = ""
if pumaws_config.has_section("default"):
    lastuser = pumaws_config.get("default", "username")

# Get the federated credentials from the user
print("Warning: This script will overwrite your AWS credentials stored at "+credentials_path+", section ["+section+"]\n")
if lastuser != "":
    username = input("Privileged user (e.g. adm\dev_aly) [" + lastuser + "]: ")
else:
    username = input("Privileged user (e.g. adm\dev_aly): ")

if username == "":
    username = lastuser

password = getpass.getpass(prompt='Domain password: ')

# Save last used user name
if lastuser != username and username is not None and username != "":
    if not pumaws_config.has_section("default"):
        pumaws_config.add_section("default")
    pumaws_config.set("default", 'username', username)
    with open(pumaws_configpath, 'w') as configfile:
        pumaws_config.write(configfile)

# 1st HTTP request: GET the login form
session = requests.Session()
# Parse the response and extract all the necessary values
formresponse = session.get(idpentryurl, verify=sslverification, allow_redirects=True)
idpauthformsubmiturl = formresponse.url
formsoup = BeautifulSoup(formresponse.text, 'html.parser') #.decode('utf8')
payload = {}
for inputtag in formsoup.find_all(re.compile('(INPUT|input)')):
    name = inputtag.get('name', '')
    value = inputtag.get('value', '')
    if "username" in name.lower():
        payload[name] = username
    elif "authmethod" in name.lower():
        payload[name] = "FormsAuthentication"
    elif "password" in name.lower():
        payload[name] = password
    else:
        #Simply populate the parameter with the existing value (picks up hidden fields in the login form)
        payload[name] = value

# 2nd HTTP request: POST the username and password
response = session.post(idpauthformsubmiturl, data=payload, verify=sslverification, allow_redirects=True)
#Get the challenge token from the user to pass to LinOTP (challengeQuestionInput)
print("Visma Google Auth 2FA Token:", end=" ")
token = input()
# Build nested data structure, parse the response and extract all the necessary values
tokensoup = BeautifulSoup(response.text, 'html.parser') #.decode('utf8')
payload = {}
for inputtag in tokensoup.find_all(re.compile('(INPUT|input)')):
    name = inputtag.get('name','')
    value = inputtag.get('value','')
    if "challenge" in name.lower():
        payload[name] = token
    elif "authmethod" in name.lower():
        payload[name] = "VismaMFAAdapter"
    else:
        #Simply populate the parameter with the existing value (picks up hidden fields in the login form)
        payload[name] = value

# 3rd HTTP request: POST the 2FA token
tokenresponse = session.post(response.url, data=payload, verify=sslverification, allow_redirects=True)

# Extract the SAML assertion and pass it to the AWS STS service
# Decode the response and extract the SAML assertion
soup = BeautifulSoup(tokenresponse.text, 'html.parser') #.decode('utf8')
assertion = ''
# Look for the SAMLResponse attribute of the input tag (determined by analyzing the debug print lines above)
for inputtag in soup.find_all('input'):
    if(inputtag.get('name') == 'SAMLResponse'):
        assertion = inputtag.get('value')
# Error handling, If ADFS does not return a SAML assertion response
if (assertion == ''):
    print('Your login failed, please contact launch control or check token/username/passwd')
    sys.exit(0)
# Parse the returned assertion and extract the authorized roles
awsroles = []
root = ET.fromstring(base64.b64decode(assertion))
for saml2attribute in root.iter('{urn:oasis:names:tc:SAML:2.0:assertion}Attribute'):
    if (saml2attribute.get('Name') == 'https://aws.amazon.com/SAML/Attributes/Role'):
        for saml2attributevalue in saml2attribute.iter('{urn:oasis:names:tc:SAML:2.0:assertion}AttributeValue'):
            awsroles.append(saml2attributevalue.text)
# Note the format of the attribute value should be role_arn,principal_arn
for awsrole in awsroles:
    chunks = awsrole.split(',')
    if'saml-provider' in chunks[0]:
        newawsrole = chunks[1] + ',' + chunks[0]
        index = awsroles.index(awsrole)
        awsroles.insert(index, newawsrole)
        awsroles.remove(awsrole)

## Filter roles based on the specified account
if account is not None:
    awsroles = list(filter(lambda x: account in x, awsroles))

# If user has more than one role, ask the user which one they want, otherwise just proceed
print("")
if len(awsroles) > 1:
    i = 0
    print("Please choose the AWS account and role you would like to assume:")
    for awsrole in awsroles:
        print('[', i, ']: ', awsrole.split(',')[0])
        i += 1
    print ("Selection:", end=" ")
    selectedroleindex = input()

    # Basic sanity check of input
    if int(selectedroleindex) > (len(awsroles) - 1):
        print('You selected an invalid role index, please try again')
        sys.exit(0)

    role_arn = awsroles[int(selectedroleindex)].split(',')[0]
    principal_arn = awsroles[int(selectedroleindex)].split(',')[1]
else:
    role_arn = awsroles[0].split(',')[0]
    principal_arn = awsroles[0].split(',')[1]

# Use the assertion to get an AWS STS token using Assume Role with SAML
client = boto3.client('sts')
token = client.assume_role_with_saml(RoleArn = role_arn, PrincipalArn = principal_arn, SAMLAssertion = assertion, DurationSeconds = tokenDuration)

# Write the AWS STS token into the AWS credential file
credentials_config = configparser.RawConfigParser()
credentials_config.read(credentials_path)
if not credentials_config.has_section(section):
    credentials_config.add_section(section)
credentials_config.set(section, 'aws_access_key_id', token['Credentials']['AccessKeyId'])
credentials_config.set(section, 'aws_secret_access_key', token['Credentials']['SecretAccessKey'])
credentials_config.set(section, 'aws_session_token', token['Credentials']['SessionToken'])
os.makedirs(os.path.dirname(credentials_path), exist_ok=True)
with open(credentials_path, 'w') as configfile:
    credentials_config.write(configfile)

# Write the AWS config file
if section != "default":
    config_section="profile " + section
else:
    config_section=section

config_config = configparser.RawConfigParser()
config_config.read(config_path)
if not config_config.has_section(config_section):
    config_config.add_section(config_section)
config_config.set(config_section, 'region', profile_region)
config_config.set(config_section, 'output', profile_output)
os.makedirs(os.path.dirname(config_path), exist_ok=True)
with open(config_path, 'w') as configfile:
    config_config.write(configfile)


# Give the user some basic info as to what has just happened
print('\n----------------------------------------------------------------')
print('Your AWS access key pair has been stored in the AWS configuration file {0}'.format(credentials_path))
print('Note that it will expire at {0}'.format(token['Credentials']['Expiration']))
print('----------------------------------------------------------------\n')
