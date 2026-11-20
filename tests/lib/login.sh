# shellcheck shell=bash
# A browser login through the oauth-proxy, with curl. Source this file; do not run it.
#
# It does what a browser does: /oauth/start, the identity provider login form, the scope
# approval form (only the first time), and /oauth/callback. It works with bash 3.2 (macOS).
#
# The caller sets:
#   HOST     the host of the Route, for example hello-nginx-demo-rnd.apps-crc.testing
#   CA_FILE  the CA of the router certificate (the ConfigMap default-ingress-cert)
#   IDP      the name of the identity provider, for example ldap-local
#   WORK     a private temporary directory for the HTML pages

# _curl JAR ARGS...: curl with the router CA and a cookie jar that it reads and writes.
_curl() {
  local jar=$1
  shift
  curl -s --cacert "$CA_FILE" -c "$jar" -b "$jar" "$@"
}

# _field NAME FILE: the value of the form field NAME in the HTML file, unescaped.
_field() {
  grep -oE "name=\"$1\"[^>]*value=\"[^\"]*\"" "$2" | head -1 \
    | sed -E 's/.*value="([^"]*)"/\1/' | sed -e 's/&amp;/\&/g' -e 's/&#43;/+/g'
}

# login USER PASSWORD JAR
# Logs USER in, and keeps the proxy session cookie in JAR (start with a new JAR, as in a
# private browser window). Prints the HTTP status of /oauth/callback:
#   302  the proxy admitted the user (the session cookie is in JAR)
#   403  the proxy refused the user ("Permission Denied")
#   500  the code exchange failed ("Internal Error")
# Returns 1, with a message on stderr, if a step of the login does not work.
login() {
  local user=$1 password=$2 jar=$3
  local auth login_url oauth next url out code i
  rm -f "$jar"

  auth=$(_curl "$jar" -o /dev/null -w '%{redirect_url}' "https://$HOST/oauth/start")
  case "$auth" in
    */oauth/authorize*) ;;
    *) echo "login: /oauth/start did not redirect to the OAuth server (got: '$auth')" >&2; return 1 ;;
  esac
  oauth=${auth%%/oauth/authorize*}

  # Select the identity provider, then read the login form.
  login_url=$(_curl "$jar" -o /dev/null -w '%{redirect_url}' "$auth&idp=$IDP")
  [ -n "$login_url" ] || { echo "login: no login page for the identity provider '$IDP'" >&2; return 1; }
  _curl "$jar" -o "$WORK/login.html" "$login_url"

  next=$(_curl "$jar" -o /dev/null -w '%{http_code} %{redirect_url}' -X POST "${login_url%%\?*}" \
    --data-urlencode "then=$(_field "then" "$WORK/login.html")" \
    --data-urlencode "csrf=$(_field csrf "$WORK/login.html")" \
    --data-urlencode "username=$user" \
    --data-urlencode "password=$password")
  url=${next#* }
  # A wrong password also answers 302, back to the login page of the identity provider.
  case "${next%% *} $url" in
    302\ */login/*|302\ ) echo "login: the identity provider refused $user. Check the user name and the password." >&2; return 1 ;;
    302\ *) ;;
    *) echo "login: the login form answered status ${next%% *} for $user" >&2; return 1 ;;
  esac

  # Follow the redirects to /oauth/callback, and approve the scopes if the server asks.
  i=0
  while [ $i -lt 8 ]; do
    i=$((i + 1))
    out=$(_curl "$jar" -o "$WORK/step.html" -w '%{http_code} %{redirect_url}' "$url")
    code=${out%% *}
    case "$url" in
      "https://$HOST/oauth/callback"*) echo "$code"; return 0 ;;
    esac
    if grep -q 'action="approve"' "$WORK/step.html"; then
      out=$(_curl "$jar" -o /dev/null -w '%{http_code} %{redirect_url}' -X POST "$oauth/oauth/authorize/approve" \
        --data-urlencode "then=$(_field "then" "$WORK/step.html")" \
        --data-urlencode "csrf=$(_field csrf "$WORK/step.html")" \
        --data-urlencode "client_id=$(_field client_id "$WORK/step.html")" \
        --data-urlencode "user_name=$(_field user_name "$WORK/step.html")" \
        --data-urlencode "redirect_uri=$(_field redirect_uri "$WORK/step.html")" \
        --data-urlencode "scope=user:info" \
        --data-urlencode "scope=user:check-access" \
        --data-urlencode "approve=Allow selected permissions")
      code=${out%% *}
    fi
    if [ "$code" != 302 ]; then
      echo "login: unexpected status $code at ${url%%\?*}" >&2
      return 1
    fi
    url=${out#* }
  done
  echo "login: too many redirects for $user" >&2
  return 1
}
