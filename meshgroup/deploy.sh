#!/bin/sh
# Puts the mesh group mailing list on AWS: one CloudFormation stack (table, mailbox bucket, Lambda, sign-up page URL, SES receiving rule, bounce reports).
# Safe to run again: it updates the stack in place (the member list is kept; the table is never deleted with the stack).
#
#   meshgroup/deploy.sh              do it
#   DRY_RUN=1 meshgroup/deploy.sh    check the template and show what it would do, change nothing
#
# Uses the AWS CLI's default profile. Settings (environment): REGION (us-west-2), LIST_ADDRESS (meshgroup@xerokuhl.com), LIST_NAME, POSTING (anyone|members),
# SITE_HOST (where the pages are served: groups.xerokuhl.com; needs the certificate that domain.sh makes), SEND_PAUSE (seconds between messages; 1.05 in the SES sandbox).
#
# Not done here (it is your domain and your account):
#   - the MX record that sends mail for the list address to SES (printed at the end; mail for the whole domain goes there)
#   - getting SES out of the sandbox: until then it only delivers to addresses you have verified, so sign-ups from the public will not receive mail
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REGION="${REGION:-us-west-2}"
DOMAIN="${DOMAIN:-xerokuhl.com}"
LIST_ADDRESS="${LIST_ADDRESS:-meshgroup@$DOMAIN}"
LIST_NAME="${LIST_NAME:-Mesh Group}"
POSTING="${POSTING:-anyone}"
SITE_HOST="${SITE_HOST:-groups.$DOMAIN}"
SEND_PAUSE="${SEND_PAUSE:-1.05}"
STACK="${STACK:-meshgroup}"
DRY_RUN="${DRY_RUN:-0}"
export AWS_DEFAULT_REGION="$REGION"

say() { printf '%s\n' "$*"; }
change() { if [ "$DRY_RUN" = 1 ]; then say "  [dry run] $*" >&2; else "$@"; fi; }

aws sts get-caller-identity >/dev/null 2>&1 || { say "Not signed in to AWS. Run: aws sso login" >&2; exit 1; }
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
say "Account $ACCOUNT, region $REGION, list $LIST_ADDRESS"

say "1. checking the template"
aws cloudformation validate-template --template-body "file://$HERE/template.yaml" >/dev/null

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "2. packaging the code"
(cd "$HERE" && python3 -m zipfile -c "$TMP/code.zip" app.py console.py pages.py store.py handler.py)
SUM="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:16])" "$TMP/code.zip")"
CODE_BUCKET="meshgroup-code-$ACCOUNT-$REGION"
CODE_KEY="code/meshgroup-$SUM.zip"
if ! aws s3api head-bucket --bucket "$CODE_BUCKET" >/dev/null 2>&1; then
  say "   making the bucket $CODE_BUCKET for the code"
  change aws s3api create-bucket --bucket "$CODE_BUCKET" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  change aws s3api put-public-access-block --bucket "$CODE_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi
change aws s3 cp --only-show-errors "$TMP/code.zip" "s3://$CODE_BUCKET/$CODE_KEY"

say "3. the certificate for $SITE_HOST"
CERT="$(aws acm list-certificates --certificate-statuses ISSUED --query "CertificateSummaryList[?DomainName=='$SITE_HOST'].CertificateArn | [0]" --output text)"
if [ -z "$CERT" ] || [ "$CERT" = None ]; then
  say "   there is no issued certificate for $SITE_HOST in $REGION: run meshgroup/domain.sh (it makes one and adds the DNS records)" >&2
  [ "$DRY_RUN" = 1 ] && CERT=arn:aws:acm:$REGION:$ACCOUNT:certificate/dry-run || exit 1
fi

say "4. the SES receipt rule set"
ACTIVE="$(aws ses describe-active-receipt-rule-set --query 'Metadata.Name' --output text 2>/dev/null || true)"
if aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id RuleSet >/dev/null 2>&1; then
  RULESET="$(aws cloudformation describe-stack-resource --stack-name "$STACK" --logical-resource-id RuleSet --query StackResourceDetail.PhysicalResourceId --output text)"; CREATE=true
  say "   the stack already owns the rule set $RULESET: kept"
elif [ -z "$ACTIVE" ] || [ "$ACTIVE" = None ]; then
  RULESET=meshgroup; CREATE=true
  say "   none is active: the stack makes one called $RULESET (activate it afterwards: see the end)"
else
  RULESET="$ACTIVE"; CREATE=false
  say "   the active one is $ACTIVE: the rule is added to it"
fi

say "5. the stack $STACK"
change aws cloudformation deploy --stack-name "$STACK" --template-file "$HERE/template.yaml" --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset --parameter-overrides \
  "ListAddress=$LIST_ADDRESS" "ListName=$LIST_NAME" "Posting=$POSTING" "DomainName=$SITE_HOST" "CertificateArn=$CERT" "SendPause=$SEND_PAUSE" \
  "CodeBucket=$CODE_BUCKET" "CodeKey=$CODE_KEY" "RuleSetName=$RULESET" "CreateRuleSet=$CREATE"

say
if [ "$DRY_RUN" = 1 ]; then say "Dry run: nothing was changed."; exit 0; fi
URL="$(aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='SignUpPage'].OutputValue" --output text)"
say "Done. The sign-up page: $URL   (the owner page is ${URL}admin; set its password with: python3 meshgroup/admin.py passwd)"
say
say "Still to do:"
[ "$CREATE" = true ] && [ "$ACTIVE" != "$RULESET" ] && say "  - activate the rule set:  aws ses set-active-receipt-rule-set --rule-set-name $RULESET --region $REGION"
say "  - the MX record for $DOMAIN:  10 inbound-smtp.$REGION.amazonaws.com   (mail for every @$DOMAIN address then goes to SES, which accepts only $LIST_ADDRESS)"
say "  - SES production access (console: SES > Account dashboard > Request production access); until then only verified addresses get mail"
say "  - put your own list in:  python3 meshgroup/admin.py add people.txt"
