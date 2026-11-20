#!/usr/bin/env bash
# End-to-end test of the tutorial: who can open the page behind the oauth-proxy.
# Read tests/README.md first. It changes the group of the viewer during the run, and
# puts it back at the end, also when a check fails.
set -uo pipefail

# The settings. The defaults are the demo of the tutorial.
NAMESPACE=${NAMESPACE:-demo-rnd}
ROUTE=${ROUTE:-hello-nginx}
OAUTH_CLIENT=${OAUTH_CLIENT:-hello-oauth-proxy}
IDP=${IDP:-ldap-local}
VIEWER_USER=${VIEWER_USER:-jane.smith}
VIEWER_GROUP=${VIEWER_GROUP:-demo-rnd-viewers}
EDITOR_USER=${EDITOR_USER:-john.doe}
OUTSIDER_USER=${OUTSIDER_USER:-alice.cooper}

missing=""
for v in VIEWER_PASSWORD EDITOR_PASSWORD OUTSIDER_PASSWORD; do
  eval "[ -n \"\${$v:-}\" ]" || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "Set the passwords of the test users in the environment:$missing" >&2
  exit 2
fi
oc whoami >/dev/null 2>&1 || { echo "Log in with oc as a cluster administrator first." >&2; exit 2; }

# A private work directory: it holds session cookies, so it is deleted at the end.
WORK=$(mktemp -d)
removed_viewer=no
cleanup() {
  if [ "$removed_viewer" = yes ]; then
    oc adm groups add-users "$VIEWER_GROUP" "$VIEWER_USER" >/dev/null && echo "(put $VIEWER_USER back in $VIEWER_GROUP)"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
# Ctrl-C or kill: exit, so that the EXIT trap puts the viewer back.
trap 'exit 130' INT TERM

# shellcheck source-path=SCRIPTDIR source=lib/login.sh
. "$(dirname "$0")/lib/login.sh"

HOST=$(oc -n "$NAMESPACE" get route "$ROUTE" -o jsonpath='{.status.ingress[0].host}')
[ -n "$HOST" ] || { echo "The Route $ROUTE in $NAMESPACE has no host." >&2; exit 2; }
CA_FILE=$WORK/ingress-ca.crt
oc -n openshift-config-managed get configmap default-ingress-cert -o jsonpath='{.data.ca-bundle\.crt}' > "$CA_FILE"
export HOST CA_FILE IDP WORK

failures=0
check() { # check NAME WANT GOT
  if [ "$2" = "$3" ]; then
    echo "PASS  $1 (got: $3)"
  else
    echo "FAIL  $1 (want: $2, got: $3)"
    failures=$((failures + 1))
  fi
}
status() { # status JAR PATH: the HTTP status of a page with the session in JAR
  curl -s --cacert "$CA_FILE" -b "$1" -o /dev/null -w '%{http_code}' "https://$HOST$2"
}
body() { # body JAR PATH
  curl -s --cacert "$CA_FILE" -b "$1" "https://$HOST$2"
}

echo "Testing https://$HOST/ (namespace $NAMESPACE, identity provider $IDP)"

# The router loads a new Route some seconds after it is created.
i=0
while [ "$(status /dev/null /)" = 503 ] && [ $i -lt 30 ]; do i=$((i + 1)); sleep 2; done

# R1: a user who is not logged in gets the sign-in page, never the content.
check "not logged in: / is the sign-in page" 403 "$(status /dev/null /)"
start=$(curl -s --cacert "$CA_FILE" -o /dev/null -w '%{http_code} %{redirect_url}' "https://$HOST/oauth/start")
check "/oauth/start redirects to the OAuth server" 302 "${start%% *}"
case "$start" in
  *"client_id=system%3Aserviceaccount%3A$NAMESPACE%3A$OAUTH_CLIENT"*) got=yes ;;
  *) got=no ;;
esac
check "the client_id is the ServiceAccount $OAUTH_CLIENT" yes "$got"

# R2: a user with no role in the namespace is refused.
check "$OUTSIDER_USER (no group) is refused" 403 "$(login "$OUTSIDER_USER" "$OUTSIDER_PASSWORD" "$WORK/outsider")"

# R2, R3: the viewer (view) and the editor (edit) are admitted.
check "$VIEWER_USER (view) is admitted" 302 "$(login "$VIEWER_USER" "$VIEWER_PASSWORD" "$WORK/viewer")"
check "$VIEWER_USER gets the page" 200 "$(status "$WORK/viewer" /)"
case "$(body "$WORK/viewer" /)" in
  *"Signed in as $VIEWER_USER"*) got=yes ;;
  *) got=no ;;
esac
check "the page shows $VIEWER_USER" yes "$got"
check "/whoami as $VIEWER_USER" "user=$VIEWER_USER" "$(body "$WORK/viewer" /whoami)"
check "$EDITOR_USER (edit) is admitted" 302 "$(login "$EDITOR_USER" "$EDITOR_PASSWORD" "$WORK/editor")"
check "/whoami as $EDITOR_USER" "user=$EDITOR_USER" "$(body "$WORK/editor" /whoami)"

# The proxy checks access only at login: a removed member keeps the session until sign-out.
oc adm groups remove-users "$VIEWER_GROUP" "$VIEWER_USER" >/dev/null && removed_viewer=yes
check "removed $VIEWER_USER keeps the session" 200 "$(status "$WORK/viewer" /)"
curl -s --cacert "$CA_FILE" -b "$WORK/viewer" -c "$WORK/viewer" -o /dev/null "https://$HOST/oauth/sign_out"
check "after sign-out the session is gone" 403 "$(status "$WORK/viewer" /)"
check "removed $VIEWER_USER is refused at a new login" 403 "$(login "$VIEWER_USER" "$VIEWER_PASSWORD" "$WORK/viewer")"
oc adm groups add-users "$VIEWER_GROUP" "$VIEWER_USER" >/dev/null && removed_viewer=no
check "$VIEWER_USER is admitted again" 302 "$(login "$VIEWER_USER" "$VIEWER_PASSWORD" "$WORK/viewer")"

echo "RESULT: $failures failure(s)"
[ "$failures" -eq 0 ]
