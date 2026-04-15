#!/usr/bin/env bash
# kamel-dev.sh — Manage Kamel dev environment on-demand resources
#
# Two on-demand resource groups:
#   1. SSM VPC Endpoints (3) — created/deleted via AWS CLI, billed per-hour
#   2. Aurora Cluster        — stopped/started, billed per ACU-hour
#
# Usage:
#   ./kamel-dev.sh up         Create SSM endpoints + start Aurora
#   ./kamel-dev.sh down       Delete SSM endpoints + stop Aurora
#   ./kamel-dev.sh db-start   Start Aurora only
#   ./kamel-dev.sh db-stop    Stop Aurora only
#   ./kamel-dev.sh status     Show current state and cost estimate
#
# Prerequisites:
#   - AWS CLI v2
#   - AWS profile 'aws-kamel' configured
#   - Stacks deployed: kamel-network-dev, kamel-data-dev

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

PROFILE="aws-kamel"
REGION="ap-south-1"
ENV="dev"
DATA_STACK="kamel-data-${ENV}"

TAG_KEY="kamel:managed-by"
TAG_VALUE="kamel-dev-script"

SSM_SERVICES=("ssm" "ssmmessages" "ec2messages")

# ── Formatting ────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}>>>${NC} $*"; }
warn()  { echo -e "${YELLOW}>>>${NC} $*"; }
error() { echo -e "${RED}>>>${NC} $*" >&2; }

# ── Helpers ───────────────────────────────────────────────────────────────────

aws_cmd() {
  aws "$@" --profile "$PROFILE" --region "$REGION"
}

get_export() {
  aws_cmd cloudformation list-exports \
    --query "Exports[?Name=='$1'].Value | [0]" --output text
}

get_stack_resource() {
  aws_cmd cloudformation describe-stack-resource \
    --stack-name "$1" --logical-resource-id "$2" \
    --query "StackResourceDetail.PhysicalResourceId" --output text 2>/dev/null || echo ""
}

get_managed_endpoint_ids() {
  aws_cmd ec2 describe-vpc-endpoints \
    --filters \
      "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
      "Name=vpc-endpoint-state,Values=available,pending,pendingAcceptance" \
    --query "VpcEndpoints[].VpcEndpointId" --output text
}

get_managed_endpoint_count() {
  local ids
  ids=$(get_managed_endpoint_ids)
  if [[ -z "$ids" ]]; then echo 0; else echo "$ids" | wc -w | tr -d ' '; fi
}

get_aurora_cluster_id() {
  get_stack_resource "$DATA_STACK" "AuroraCluster"
}

get_aurora_status() {
  local cluster_id
  cluster_id=$(get_aurora_cluster_id)
  if [[ -z "$cluster_id" || "$cluster_id" == "None" ]]; then
    echo "not-found"; return
  fi
  aws_cmd rds describe-db-clusters \
    --db-cluster-identifier "$cluster_id" \
    --query "DBClusters[0].Status" --output text 2>/dev/null || echo "not-found"
}

# ── SSM Endpoints ─────────────────────────────────────────────────────────────

endpoints_up() {
  local vpc_id subnet1 subnet2 vpce_sg
  vpc_id=$(get_export "KamelVpc-${ENV}")
  subnet1=$(get_export "KamelPrivateSubnet1-${ENV}")
  subnet2=$(get_export "KamelPrivateSubnet2-${ENV}")
  vpce_sg=$(get_export "KamelVpcEndpointSG-${ENV}")

  local existing_count
  existing_count=$(get_managed_endpoint_count)

  if [[ "$existing_count" -ge "${#SSM_SERVICES[@]}" ]]; then
    info "SSM endpoints already exist (${existing_count} found). Skipping."
    return
  fi

  if [[ "$existing_count" -gt 0 ]]; then
    warn "Found ${existing_count} partial endpoints. Cleaning up..."
    aws_cmd ec2 delete-vpc-endpoints --vpc-endpoint-ids $(get_managed_endpoint_ids) > /dev/null
    sleep 5
  fi

  info "Creating SSM VPC endpoints..."
  for svc in "${SSM_SERVICES[@]}"; do
    local epid
    epid=$(aws_cmd ec2 create-vpc-endpoint \
      --vpc-id "$vpc_id" \
      --service-name "com.amazonaws.${REGION}.${svc}" \
      --vpc-endpoint-type Interface \
      --subnet-ids "$subnet1" "$subnet2" \
      --security-group-ids "$vpce_sg" \
      --private-dns-enabled \
      --tag-specifications "ResourceType=vpc-endpoint,Tags=[{Key=Name,Value=kamel-${svc}-endpoint-${ENV}},{Key=Environment,Value=${ENV}},{Key=Project,Value=kamel-network},{Key=${TAG_KEY},Value=${TAG_VALUE}}]" \
      --query "VpcEndpoint.VpcEndpointId" --output text)
    info "  ${svc} -> ${epid}"
  done

  info "Waiting for endpoints to become available..."
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    local pending
    pending=$(aws_cmd ec2 describe-vpc-endpoints \
      --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" \
      --query "VpcEndpoints[?State!='available'].VpcEndpointId" --output text)
    if [[ -z "$pending" ]]; then
      echo ""
      info "All SSM endpoints are available."
      return
    fi
    printf "."
    sleep 10
    attempts=$((attempts + 1))
  done
  warn "Timed out waiting. Run '$0 status' to check."
}

endpoints_down() {
  local endpoint_ids
  endpoint_ids=$(get_managed_endpoint_ids)

  if [[ -n "$endpoint_ids" ]]; then
    local count
    count=$(echo "$endpoint_ids" | wc -w | tr -d ' ')
    info "Deleting ${count} SSM VPC endpoints..."
    aws_cmd ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint_ids > /dev/null
    info "Endpoints deleted. Hourly billing stopped."
  else
    info "No SSM endpoints found. Nothing to delete."
  fi
}

# ── Aurora ────────────────────────────────────────────────────────────────────

aurora_start() {
  local cluster_id status
  cluster_id=$(get_aurora_cluster_id)
  status=$(get_aurora_status)

  case "$status" in
    available) info "Aurora '${cluster_id}' is already running." ;;
    starting)  info "Aurora '${cluster_id}' is already starting..." ;;
    stopped)
      info "Starting Aurora '${cluster_id}'..."
      aws_cmd rds start-db-cluster --db-cluster-identifier "$cluster_id" > /dev/null
      info "Aurora starting. Takes 2-5 minutes."
      ;;
    *)
      error "Aurora in state '${status}'. Cannot start."
      exit 1
      ;;
  esac
}

aurora_stop() {
  local cluster_id status
  cluster_id=$(get_aurora_cluster_id)
  status=$(get_aurora_status)

  case "$status" in
    stopped)  info "Aurora '${cluster_id}' is already stopped." ;;
    stopping) info "Aurora '${cluster_id}' is already stopping..." ;;
    available)
      info "Stopping Aurora '${cluster_id}'..."
      aws_cmd rds stop-db-cluster --db-cluster-identifier "$cluster_id" > /dev/null
      info "Aurora stopping. Compute billing stops once fully stopped."
      warn "AWS auto-restarts stopped clusters after 7 days. Re-run '$0 db-stop' if needed."
      ;;
    *)
      error "Aurora in state '${status}'. Cannot stop."
      exit 1
      ;;
  esac
}

# ── Status ────────────────────────────────────────────────────────────────────

show_status() {
  echo ""
  echo -e "${BOLD}=== Kamel Dev Environment ===${NC}"
  echo ""

  local cluster_id aurora_status
  cluster_id=$(get_aurora_cluster_id)
  aurora_status=$(get_aurora_status)

  printf "  %-20s" "Aurora:"
  case "$aurora_status" in
    available) echo -e "${GREEN}running${NC}  ($cluster_id)" ;;
    stopped)   echo -e "${YELLOW}stopped${NC}  ($cluster_id)" ;;
    starting)  echo -e "${YELLOW}starting${NC} ($cluster_id)" ;;
    stopping)  echo -e "${YELLOW}stopping${NC} ($cluster_id)" ;;
    *)         echo -e "${RED}${aurora_status}${NC}" ;;
  esac

  local endpoint_count
  endpoint_count=$(get_managed_endpoint_count)

  printf "  %-20s" "SSM Endpoints:"
  if [[ "$endpoint_count" -gt 0 ]]; then
    echo -e "${GREEN}${endpoint_count} active${NC}  (~\$0.06/hr)"
  else
    echo -e "${YELLOW}none${NC}     (not billing)"
  fi

  echo ""
  echo -e "  ${BOLD}Cost estimate:${NC}"

  local always_on="46.60"
  echo "  Always-on (3 VPC endpoints + Secrets Manager):  ~\$${always_on}/month"

  local extra="0"
  if [[ "$aurora_status" == "available" ]]; then
    echo "  + Aurora (0.5 ACU):                              ~\$43.80/month"
    extra=$(echo "$extra + 43.80" | bc)
  fi
  if [[ "$endpoint_count" -gt 0 ]]; then
    local ep_cost
    ep_cost=$(echo "$endpoint_count * 14.60" | bc)
    echo "  + SSM Endpoints (${endpoint_count}):                            ~\$${ep_cost}/month"
    extra=$(echo "$extra + $ep_cost" | bc)
  fi

  local total
  total=$(echo "$always_on + $extra" | bc)
  echo "  ─────────────────────────────────────────────────"
  echo -e "  ${BOLD}Current burn rate:                                 ~\$${total}/month${NC}"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  up         Create SSM endpoints + start Aurora
  down       Delete SSM endpoints + stop Aurora
  db-start   Start Aurora only (for API/Lambda testing)
  db-stop    Stop Aurora only
  status     Show current state and cost estimate
EOF
}

case "${1:-}" in
  up)
    aurora_start
    echo ""
    endpoints_up
    ;;
  down)
    endpoints_down
    echo ""
    aurora_stop
    ;;
  db-start)  aurora_start ;;
  db-stop)   aurora_stop ;;
  status)    show_status ;;
  -h|--help) usage ;;
  *)         usage; exit 1 ;;
esac
