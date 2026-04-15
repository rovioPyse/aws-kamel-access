# Database Access via SSM Port Forwarding

This guide explains how to connect to the Aurora PostgreSQL database from a local machine using AWS Systems Manager Session Manager and the Kamel jumpbox.

## Why SSM Instead of a Bastion Host

Traditional database access used a bastion host with a public IP and open SSH port. SSM Session Manager replaces that entirely.

**Traditional bastion:**

```
Laptop → SSH (port 22) → Public Bastion Host → Aurora
```

Problems:
- Requires SSH port 22 open to the internet
- Requires SSH key management and distribution
- Bastion needs a public IP
- Harder to audit user access

**Our setup:**

```
Laptop → AWS CLI (SSM) → AWS SSM Service → VPC Endpoint → Jumpbox EC2 (private) → Aurora
```

Benefits:
- No open ports to the internet
- No public IP on the jumpbox
- Access controlled via IAM
- Full audit logs in CloudTrail
- Works from any machine with AWS CLI and valid credentials

## Infrastructure Components

**Jumpbox EC2** — A small private EC2 instance in the VPC. No public IP. Accessible only through SSM. Has network access to Aurora via the `JumpboxSG → AuroraSG` security group rule on port 5432.

**SSM VPC Endpoints** — Three interface endpoints (`ssm`, `ssmmessages`, `ec2messages`) allow the jumpbox to communicate with the AWS SSM service without internet access. These are managed by `kamel-dev.sh` and must be running before you can open a session.

## Prerequisites

**AWS CLI v2**

```bash
aws --version
```

Install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

**Session Manager Plugin**

```bash
session-manager-plugin
```

macOS:
```bash
brew install --cask session-manager-plugin
```

Linux:
```bash
sudo snap install session-manager-plugin
```

Windows: Download from the AWS documentation page linked above.

**AWS credentials**

```bash
aws configure --profile aws-kamel
aws sts get-caller-identity --profile aws-kamel
```

## Jumpbox Schedule

The jumpbox runs on weekdays only:

| Days | Start | Stop |
|---|---|---|
| Monday – Friday | 9:30 AM IST | 6:30 PM IST |

Outside these hours the instance is stopped. If you need access outside the schedule, start it manually:

```bash
aws ec2 start-instances \
  --instance-ids INSTANCE_ID \
  --profile aws-kamel \
  --region ap-south-1
```

## Starting the SSM Tunnel

Run this command, replacing `INSTANCE_ID` with the jumpbox instance ID and `AURORA_ENDPOINT` with the Aurora cluster endpoint.

You can find both values from CloudFormation stack outputs:
- Instance ID: `KamelJumpboxInstanceId-dev` / `KamelJumpboxInstanceId-prod`
- Aurora endpoint: `KamelAuroraEndpoint-dev` / `KamelAuroraEndpoint-prod`

**macOS / Linux:**

```bash
aws ssm start-session \
  --target INSTANCE_ID \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["AURORA_ENDPOINT"],"portNumber":["5432"],"localPortNumber":["5432"]}' \
  --profile aws-kamel \
  --region ap-south-1
```

**Windows CMD:**

```cmd
aws ssm start-session --target INSTANCE_ID --document-name AWS-StartPortForwardingSessionToRemoteHost --parameters "{\"host\":[\"AURORA_ENDPOINT\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"5432\"]}" --profile aws-kamel --region ap-south-1
```

Keep this terminal open for the duration of your session. Closing it terminates the tunnel.

## What the Tunnel Does

```
localhost:5432
     │
     │  SSM encrypted tunnel
     ▼
Jumpbox EC2 (private subnet)
     │
     │  TCP port 5432 (within VPC)
     ▼
Aurora PostgreSQL
```

Once the tunnel is open, your local machine can reach Aurora as `localhost:5432`.

## Connecting with DBeaver

Create a new PostgreSQL connection with these settings:

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | `5432` |
| Database | `kamel` |
| Username | DB user (from Secrets Manager) |
| Password | DB password (from Secrets Manager) |

Click **Test Connection** to verify.

## Daily Workflow

```bash
# 1. Ensure SSM endpoints are up (if not already)
./kamel-dev.sh up

# 2. Open the tunnel (keep this terminal open)
aws ssm start-session \
  --target INSTANCE_ID \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["AURORA_ENDPOINT"],"portNumber":["5432"],"localPortNumber":["5432"]}' \
  --profile aws-kamel \
  --region ap-south-1

# 3. Connect in DBeaver to localhost:5432

# 4. Close the terminal when done
```

## Troubleshooting

**Jumpbox not appearing in SSM:**

```bash
aws ssm describe-instance-information --profile aws-kamel --region ap-south-1
```

The jumpbox should show as `Online`. If it is missing, the instance may be stopped (check the schedule) or the SSM VPC endpoints may be down — run `./kamel-dev.sh up`.

**Connection refused on port 5432:**

- Confirm the Aurora cluster is running (`./kamel-dev.sh status`)
- Confirm you are using the correct Aurora endpoint
- Confirm the database credentials are correct

**Port 5432 already in use locally:**

If a local PostgreSQL instance is running on port 5432, use a different local port:

```bash
--parameters '{"host":["AURORA_ENDPOINT"],"portNumber":["5432"],"localPortNumber":["15432"]}'
```

Then connect DBeaver to `localhost:15432`.
