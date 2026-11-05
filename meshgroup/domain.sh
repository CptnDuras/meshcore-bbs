#!/bin/sh
# Puts the list on its own address (groups.xerokuhl.com) and finishes the DNS the list needs. Run it once, by you: it changes your DNS.
#
#   meshgroup/domain.sh              do it
#   DRY_RUN=1 meshgroup/domain.sh    show each step, change nothing
#
# What it does, in order (every step can be run again):
#   1. asks ACM for a certificate for the page's address and adds the one DNS record that proves you own it, then waits for it
#   2. adds the records SES needs for xerokuhl.com: DKIM, custom MAIL FROM, DMARC (monitor only) and the MX that sends list mail to SES (tools/ses-dns.json)
#   3. runs deploy.sh (which needs the certificate)
#   4. points groups.xerokuhl.com at the deployed page
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REGION="${REGION:-us-west-2}"
DOMAIN="${DOMAIN:-xerokuhl.com}"
SITE_HOST="${SITE_HOST:-groups.$DOMAIN}"
STACK="${STACK:-meshgroup}"
DRY_RUN="${DRY_RUN:-0}"
export AWS_DEFAULT_REGION="$REGION"

say() { printf '%s\n' "$*"; }
change() { if [ "$DRY_RUN" = 1 ]; then say "  [dry run] $*" >&2; else "$@"; fi; }

aws sts get-caller-identity >/dev/null 2>&1 || { say "Not signed in to AWS. Run: aws sso login" >&2; exit 1; }
ZONE="${HOSTED_ZONE:-$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --max-items 1 --query 'HostedZones[0].Id' --output text | sed 's|/hostedzone/||')}"
[ -n "$ZONE" ] && [ "$ZONE" != None ] || { say "No Route 53 hosted zone for $DOMAIN" >&2; exit 1; }
say "Zone $ZONE for $DOMAIN, page at $SITE_HOST"

# one change to the zone: upsert NAME TYPE VALUE
upsert() {
  printf '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"%s","TTL":300,"ResourceRecords":[{"Value":"%s"}]}}]}' "$1" "$2" "$3" > "$TMP/one.json"
  change aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "file://$TMP/one.json" >/dev/null
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "1. the certificate"
CERT="$(aws acm list-certificates --certificate-statuses PENDING_VALIDATION ISSUED --query "CertificateSummaryList[?DomainName=='$SITE_HOST'].CertificateArn | [0]" --output text)"
if [ -z "$CERT" ] || [ "$CERT" = None ]; then
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] would request a certificate for $SITE_HOST"
    CERT=dry-run
  else
    CERT="$(aws acm request-certificate --domain-name "$SITE_HOST" --validation-method DNS --query CertificateArn --output text)"
  fi
fi
say "   $CERT"
if [ "$CERT" != dry-run ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    REC="$(aws acm describe-certificate --certificate-arn "$CERT" --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]' --output text)"
    [ -n "$REC" ] && [ "$REC" != None ] && break
    sleep 3
  done
  NAME="$(printf '%s' "$REC" | cut -f1)"; VALUE="$(printf '%s' "$REC" | cut -f2)"
  upsert "$NAME" CNAME "$VALUE"
  say "   waiting for AWS to see the record (usually a few minutes)"
  change aws acm wait certificate-validated --certificate-arn "$CERT"
fi

say "2. the records SES needs for $DOMAIN"
change aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "file://$HERE/../tools/ses-dns.json" >/dev/null

say "3. deploying"
"$HERE/deploy.sh"

say "4. pointing $SITE_HOST at the page"
if [ "$DRY_RUN" = 1 ]; then say "  [dry run] would add an alias record for $SITE_HOST"; exit 0; fi
OUT() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
TARGET="$(OUT AliasTarget)"; TARGET_ZONE="$(OUT AliasZone)"
printf '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","AliasTarget":{"HostedZoneId":"%s","DNSName":"%s","EvaluateTargetHealth":false}}}]}' \
  "$SITE_HOST" "$TARGET_ZONE" "$TARGET" > "$TMP/alias.json"
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "file://$TMP/alias.json" >/dev/null
say "Done: https://$SITE_HOST/ (DNS can take a few minutes to reach everyone)"
say "Next: python3 meshgroup/admin.py passwd     then log in at https://$SITE_HOST/admin"
