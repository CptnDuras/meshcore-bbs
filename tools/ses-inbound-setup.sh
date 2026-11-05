#!/bin/sh
# One-time AWS setup for mail sent TO the list address (meshbbs@xerokuhl.com): SES receives it and leaves it in a private bucket, the daemon fetches it.
# Run tools/ses-setup.sh first (the domain identity and the daemon's IAM user). Safe to run again: each step checks before it changes anything.
#
#   tools/ses-inbound-setup.sh              do it
#   DRY_RUN=1 tools/ses-inbound-setup.sh    show every change it would make, make none
#
# What it does, for DOMAIN (default xerokuhl.com) in REGION (default us-west-2), using the AWS CLI's default profile:
#   1. makes a private S3 bucket (no public access, only SES may put mail in it, encrypted in transit and at rest) that empties itself after 14 days,
#      so mail the daemon never collects does not sit there
#   2. makes the SES receipt rule that sends mail for LIST_ADDRESS to that bucket, with SES's spam and virus scan on. If the account already has an
#      active receipt rule set the rule is added to it; the active set is never switched.
#   3. adds the MX record at the domain's top, pointing at SES's receiving endpoint. If the domain already has an MX record it stops: mail for the
#      domain goes wherever its MX says, and that should be your decision (set FORCE_MX=1 to replace it).
#   4. lets the daemon's IAM user list, read and delete mail in the bucket's inbound/ folder and nothing else
#   5. adds the list settings to the daemon's settings file, if they are not there
#
# After this, EVERY address @DOMAIN is received by SES (the MX is for the whole domain); SES accepts only mail for the rule's recipient and refuses the rest.
set -eu

DOMAIN="${DOMAIN:-xerokuhl.com}"
REGION="${AWS_REGION:-us-west-2}"
LIST_ADDRESS="${LIST_ADDRESS:-meshbbs@$DOMAIN}"
GROUP="${INBOUND_GROUP:-mesh}"
IAM_USER="${IAM_USER:-meshbbs-ses}"
CONF="${MESHBBS_SES:-$HOME/.config/meshbbs/ses.conf}"
DRY_RUN="${DRY_RUN:-0}"
RULESET="${RULESET:-meshbbs}"
RULE="meshbbs-list"

say() { printf '%s\n' "$*"; }
change() {
  if [ "$DRY_RUN" = 1 ]; then say "  [dry run] $*" >&2; else "$@"; fi   # to stderr, so a command's own ">/dev/null" does not hide it
}

aws sts get-caller-identity >/dev/null 2>&1 || { say "Not signed in to AWS. Run: aws sso login" >&2; exit 1; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${BUCKET:-meshbbs-mail-$ACCOUNT-$REGION}"
say "Account $ACCOUNT, region $REGION, list address $LIST_ADDRESS, bucket $BUCKET, group $GROUP"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1. the bucket ----
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  say "1. bucket $BUCKET exists"
else
  say "1. making the bucket $BUCKET"
  if [ "$REGION" = us-east-1 ]; then
    change aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    change aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
fi
change aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
change aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
cat > "$TMP/lifecycle.json" <<E
{"Rules":[{"ID":"empty-the-mailbox","Status":"Enabled","Filter":{"Prefix":"inbound/"},"Expiration":{"Days":14},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":2}}]}
E
change aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration "file://$TMP/lifecycle.json"
cat > "$TMP/bucket-policy.json" <<E
{"Version":"2012-10-17","Statement":[
 {"Sid":"OnlySesMayLeaveMail","Effect":"Allow","Principal":{"Service":"ses.amazonaws.com"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::$BUCKET/inbound/*",
  "Condition":{"StringEquals":{"aws:SourceAccount":"$ACCOUNT"},"StringLike":{"aws:SourceArn":"arn:aws:ses:$REGION:$ACCOUNT:receipt-rule-set/*:receipt-rule/*"}}},
 {"Sid":"NothingOverPlainHttp","Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
E
change aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$TMP/bucket-policy.json"

# ---- 2. the receipt rule ----
ACTIVE="$(aws ses describe-active-receipt-rule-set --region "$REGION" --query 'Metadata.Name' --output text 2>/dev/null || true)"
if [ -z "$ACTIVE" ] || [ "$ACTIVE" = None ]; then
  say "2. no receipt rule set is active: making $RULESET and activating it"
  aws ses describe-receipt-rule-set --region "$REGION" --rule-set-name "$RULESET" >/dev/null 2>&1 || change aws ses create-receipt-rule-set --region "$REGION" --rule-set-name "$RULESET"
  SET="$RULESET"
  ACTIVATE=1
else
  say "2. the account's active receipt rule set is $ACTIVE: adding the rule to it (it stays active)"
  SET="$ACTIVE"
  ACTIVATE=0
fi
cat > "$TMP/rule.json" <<E
{"Name":"$RULE","Enabled":true,"TlsPolicy":"Optional","Recipients":["$LIST_ADDRESS"],"ScanEnabled":true,
 "Actions":[{"S3Action":{"BucketName":"$BUCKET","ObjectKeyPrefix":"inbound/"}}]}
E
if aws ses describe-receipt-rule --region "$REGION" --rule-set-name "$SET" --rule-name "$RULE" >/dev/null 2>&1; then
  say "   the rule $RULE exists: setting it again"
  change aws ses update-receipt-rule --region "$REGION" --rule-set-name "$SET" --rule "file://$TMP/rule.json"
else
  change aws ses create-receipt-rule --region "$REGION" --rule-set-name "$SET" --rule "file://$TMP/rule.json"
fi
[ "$ACTIVATE" = 1 ] && change aws ses set-active-receipt-rule-set --region "$REGION" --rule-set-name "$SET"

# ---- 3. the MX record ----
ZONE="${HOSTED_ZONE_ID:-$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --max-items 1 \
  --query "HostedZones[?Name=='$DOMAIN.'].Id | [0]" --output text | sed 's|/hostedzone/||')}"
[ -n "$ZONE" ] && [ "$ZONE" != None ] || { say "No Route 53 hosted zone for $DOMAIN (set HOSTED_ZONE_ID)" >&2; exit 1; }
MX_NOW="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE" --query "ResourceRecordSets[?Name=='$DOMAIN.' && Type=='MX'].ResourceRecords[].Value" --output text)"
WANT_MX="10 inbound-smtp.$REGION.amazonaws.com"
if [ "$MX_NOW" = "$WANT_MX" ]; then
  say "3. the MX record for $DOMAIN is already $WANT_MX"
elif [ -n "$MX_NOW" ] && [ "${FORCE_MX:-0}" != 1 ]; then
  say "3. $DOMAIN already has an MX record ($MX_NOW), so mail for it goes somewhere else. Not changing it." >&2
  say "   Set FORCE_MX=1 to replace it with $WANT_MX (mail for the whole domain then goes to SES)." >&2
  exit 1
else
  say "3. MX $DOMAIN -> $WANT_MX"
  cat > "$TMP/mx.json" <<E
{"Comment":"SES receiving for the mesh list","Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"$DOMAIN","Type":"MX","TTL":300,"ResourceRecords":[{"Value":"$WANT_MX"}]}}]}
E
  change aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "file://$TMP/mx.json" >/dev/null
fi

# ---- 4. the daemon's access to the mailbox ----
cat > "$TMP/read.json" <<E
{"Version":"2012-10-17","Statement":[
 {"Sid":"ListTheMailbox","Effect":"Allow","Action":"s3:ListBucket","Resource":"arn:aws:s3:::$BUCKET","Condition":{"StringLike":{"s3:prefix":["inbound/*","inbound/"]}}},
 {"Sid":"ReadAndClearTheMailbox","Effect":"Allow","Action":["s3:GetObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::$BUCKET/inbound/*"}]}
E
if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1 || [ "$DRY_RUN" = 1 ]; then
  say "4. letting $IAM_USER list, read and delete mail in s3://$BUCKET/inbound/"
  change aws iam put-user-policy --user-name "$IAM_USER" --policy-name "read-the-list-mailbox" --policy-document "file://$TMP/read.json"
else
  say "4. the IAM user $IAM_USER does not exist: run tools/ses-setup.sh first" >&2
  exit 1
fi

# ---- 5. the settings file ----
if [ -f "$CONF" ]; then
  say "5. settings in $CONF:"
  for kv in "list_address=$LIST_ADDRESS" "inbound_bucket=$BUCKET" "inbound_group=$GROUP"; do
    key="${kv%%=*}"
    if grep -q "^$key=" "$CONF"; then
      say "   $key is already set"
    elif [ "$DRY_RUN" = 1 ]; then
      say "  [dry run] add $kv to $CONF"
    else
      printf '%s\n' "$kv" >> "$CONF"
      say "   added $kv"
    fi
  done
else
  say "5. $CONF does not exist yet (run tools/ses-setup.sh). Add these to it:"
  say "     list_address=$LIST_ADDRESS"; say "     inbound_bucket=$BUCKET"; say "     inbound_group=$GROUP"
fi

say
say "Done. Copy $CONF to the machine that runs the daemon and restart the daemon: it logs [inbound] taking in mail sent to $LIST_ADDRESS."
say "The group '$GROUP' has to exist (meshbbs email import $GROUP <file>). Try it by writing to $LIST_ADDRESS from an address that is on the list."
