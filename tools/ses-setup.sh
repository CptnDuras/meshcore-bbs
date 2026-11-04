#!/bin/sh
# One-time AWS setup for the BBS's email (Amazon SES). Safe to run again: each step checks before it changes anything.
#
#   tools/ses-setup.sh              do it
#   DRY_RUN=1 tools/ses-setup.sh    show every change it would make, make none
#
# What it does, for DOMAIN (default xerokuhl.com) in REGION (default us-west-2), using the AWS CLI's default profile:
#   1. makes the SES identity for the domain, with DKIM signing
#   2. adds the DNS records in Route 53: the three DKIM CNAMEs, a custom MAIL FROM subdomain (MX + SPF on mail.DOMAIN), and a monitor-only DMARC record.
#      The zone has no other mail records and these names are new, so nothing existing is touched.
#   3. makes the IAM user meshbbs-ses, which may do one thing: send mail from the domain's identity
#   4. writes its access key to the settings file the daemon reads (~/.config/meshbbs/ses.conf, readable only by you)
#   5. waits for SES to see the DNS records and mark the domain verified
#
# SES starts in "sandbox" mode: it only delivers to addresses that have been verified (each person clicks a link AWS mails them). Sending to people
# who have not is refused with "Email address is not verified". Production access (an AWS support request) removes that; it is not needed for a few people.
set -eu

DOMAIN="${DOMAIN:-xerokuhl.com}"
REGION="${AWS_REGION:-us-west-2}"
FROM="${FROM:-mesh@$DOMAIN}"
FROM_NAME="${FROM_NAME:-Buffalo Mesh}"
REPLY_TO="${REPLY_TO:-}"
MAILFROM="mail.$DOMAIN"
IAM_USER="${IAM_USER:-meshbbs-ses}"
CONF="${MESHBBS_SES:-$HOME/.config/meshbbs/ses.conf}"
DRY_RUN="${DRY_RUN:-0}"

say() { printf '%s\n' "$*"; }
# runs a changing command, or only shows it in a dry run
change() {
  if [ "$DRY_RUN" = 1 ]; then say "  [dry run] $*" >&2; else "$@"; fi   # to stderr, so a command's own ">/dev/null" does not hide it
}

aws sts get-caller-identity >/dev/null 2>&1 || { say "Not signed in to AWS. Run: aws sso login" >&2; exit 1; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
say "Account $ACCOUNT, region $REGION, domain $DOMAIN, sending as $FROM"

# ---- 1. the identity ----
if aws sesv2 get-email-identity --region "$REGION" --email-identity "$DOMAIN" >/dev/null 2>&1; then
  say "1. SES identity $DOMAIN exists"
else
  say "1. making the SES identity $DOMAIN"
  change aws sesv2 create-email-identity --region "$REGION" --email-identity "$DOMAIN" \
    --dkim-signing-attributes NextSigningKeyLength=RSA_2048_BIT >/dev/null
fi

# ---- 2. DNS ----
ZONE="${HOSTED_ZONE_ID:-$(aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" --max-items 1 \
  --query "HostedZones[?Name=='$DOMAIN.'].Id | [0]" --output text | sed 's|/hostedzone/||')}"
[ -n "$ZONE" ] && [ "$ZONE" != None ] || { say "No Route 53 hosted zone for $DOMAIN (set HOSTED_ZONE_ID)" >&2; exit 1; }
TOKENS="$(aws sesv2 get-email-identity --region "$REGION" --email-identity "$DOMAIN" --query 'DkimAttributes.Tokens' --output text 2>/dev/null || true)"
BATCH="$(mktemp)"
trap 'rm -f "$BATCH"' EXIT
{
  printf '{"Comment":"SES for the mesh BBS: DKIM, custom MAIL FROM, DMARC (monitor only)","Changes":['
  sep=''
  for t in $TOKENS; do
    printf '%s{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s._domainkey.%s","Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":"%s.dkim.amazonses.com"}]}}' "$sep" "$t" "$DOMAIN" "$t"
    sep=','
  done
  printf '%s{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"MX","TTL":300,"ResourceRecords":[{"Value":"10 feedback-smtp.%s.amazonses.com"}]}}' "$sep" "$MAILFROM" "$REGION"
  printf ',{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"TXT","TTL":300,"ResourceRecords":[{"Value":"\\"v=spf1 include:amazonses.com ~all\\""}]}}' "$MAILFROM"
  printf ',{"Action":"UPSERT","ResourceRecordSet":{"Name":"_dmarc.%s","Type":"TXT","TTL":300,"ResourceRecords":[{"Value":"\\"v=DMARC1; p=none; adkim=r; aspf=r\\""}]}}' "$DOMAIN"
  printf ']}'
} > "$BATCH"
if [ -z "$TOKENS" ]; then
  say "2. (dry run: the identity does not exist yet, so its DKIM names are not known; they are added when it does)"
else
  say "2. DNS records for $DOMAIN (zone $ZONE):"
  for t in $TOKENS; do say "     CNAME  $t._domainkey.$DOMAIN -> $t.dkim.amazonses.com"; done
  say "     MX     $MAILFROM -> 10 feedback-smtp.$REGION.amazonses.com"
  say "     TXT    $MAILFROM -> v=spf1 include:amazonses.com ~all"
  say "     TXT    _dmarc.$DOMAIN -> v=DMARC1; p=none; adkim=r; aspf=r"
  change aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "file://$BATCH" >/dev/null
  change aws sesv2 put-email-identity-mail-from-attributes --region "$REGION" --email-identity "$DOMAIN" \
    --mail-from-domain "$MAILFROM" --behavior-on-mx-failure USE_DEFAULT_VALUE
fi

# ---- 3 and 4. the sending user and its settings file ----
POLICY="$(mktemp)"
trap 'rm -f "$BATCH" "$POLICY"' EXIT
cat > "$POLICY" <<E
{"Version":"2012-10-17","Statement":[{"Sid":"SendFromTheMeshDomainOnly","Effect":"Allow","Action":["ses:SendEmail"],"Resource":"arn:aws:ses:$REGION:$ACCOUNT:identity/$DOMAIN"}]}
E
if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
  say "3. IAM user $IAM_USER exists (its permissions are set again below)"
else
  say "3. making the IAM user $IAM_USER"
  change aws iam create-user --user-name "$IAM_USER" --tags Key=purpose,Value=meshbbs-email-sending >/dev/null
fi
change aws iam put-user-policy --user-name "$IAM_USER" --policy-name send-from-$DOMAIN --policy-document "file://$POLICY"

if [ -s "$CONF" ]; then
  say "4. $CONF exists, so no new access key is made (an old key's secret cannot be shown again; delete the file to make a new key)"
else
  say "4. writing $CONF"
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] aws iam create-access-key --user-name $IAM_USER, then write the key into $CONF (mode 600)"
  else
    mkdir -p "$(dirname "$CONF")"
    umask 077
    KEY="$(aws iam create-access-key --user-name "$IAM_USER" --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text)"
    {
      printf '# written by tools/ses-setup.sh; the daemon and "meshbbs email" read this file\n'
      printf 'region=%s\naccess_key_id=%s\nsecret_access_key=%s\nfrom=%s\nfrom_name=%s\n' "$REGION" "$(printf '%s' "$KEY" | cut -f1)" "$(printf '%s' "$KEY" | cut -f2)" "$FROM" "$FROM_NAME"
      [ -n "$REPLY_TO" ] && printf 'reply_to=%s\n' "$REPLY_TO"
    } > "$CONF"
    chmod 600 "$CONF"
    say "   written (mode 600). Copy it to the machine that runs the daemon, to the same path."
  fi
fi

# ---- 5. wait for verification ----
if [ "$DRY_RUN" = 1 ]; then say "5. [dry run] would wait for SES to verify the domain"; exit 0; fi
say "5. waiting for SES to see the DNS records (usually a few minutes, up to an hour)"
i=0
while [ "$i" -lt 60 ]; do
  ok="$(aws sesv2 get-email-identity --region "$REGION" --email-identity "$DOMAIN" --query 'VerifiedForSendingStatus' --output text)"
  [ "$ok" = True ] && { say "   verified. Try: meshbbs email test you@example.com   (to an address you have verified in SES)"; exit 0; }
  i=$((i + 1)); sleep 60
done
say "   not verified yet; run this script again later. Check the records with: aws sesv2 get-email-identity --region $REGION --email-identity $DOMAIN"
