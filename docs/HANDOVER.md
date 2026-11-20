# Handover

This note gives the state of the tutorial, so that the next session can continue without the conversation that wrote it.
Update it after each work session.

## State on 2026-11-20

The tutorial is complete, and Parts 3 to 6 are measured on CRC.

| Item | State | Evidence |
|---|---|---|
| `README.md`, the tutorial | Written. markdownlint: 0 issues. | `markdownlint-cli2 README.md docs/HANDOVER.md` |
| `manifests/` | Each file parses as YAML. The `-openshift-sar` value and the redirect annotation parse as JSON. | `yq` and `jq` over every file |
| nginx configuration | Measured locally with `podman run`, and again on CRC: a connection from another pod to the pod IP on port 8080 is refused (`curl: (7) ... Connection refused`), and port 8443 (the proxy) answers 403. | Local run 2026-11-19, CRC 2026-11-20 |
| Option B Deployment | `manifests/option-b/41-deployment.yaml` equals the base Deployment with a strategic merge patch that changes the identity. Measured with `oc patch --local`. | `oc` 4.22.18, 2026-11-20 |
| Proxy and OAuth server behavior | Read from the source, and the observable results are measured on CRC. | The Sources section of `README.md` |
| Parts 3 to 6 on CRC | Run on 2026-11-20. Each expected result matched. | CRC OpenShift 4.22.14, `oc` 4.22.18. Outputs below. |

## Measured outputs on CRC, 2026-11-20

The cluster has two identity providers: `developer` (htpasswd, the users `developer` and `kubeadmin`) and `ldap-local`.
`proxy/cluster` sets `spec.trustedCA` to `enterprise-ca-bundle`.
The browser logins ran as a `curl` script with a cookie jar. It posted the login form of the `developer` provider and the scope approval form.

| Step | Output |
|---|---|
| Part 3 rollout | `successfully rolled out`, pod `2/2`. The first pulls took 1m54s (nginx) and 2m4s (oauth-proxy), so the README timeout is now 300s. |
| Proxy image | `ose-oauth-proxy-rhel9:v4.15` pulled on 4.22.14. |
| Part 4 | `kubernetes.io/tls`. Service CA count 1, trusted bundle count 147. The TLS check Job printed `OK`. |
| Part 5 anonymous | `/` 403. `/oauth/start` 302 with `client_id=system%3Aserviceaccount%3Ademo-rnd%3Ahello-oauth-proxy`. |
| 5.1 | `can-i` `no`. The first login showed the approval page for `user:info` and `user:check-access`. The callback returned 403 "Permission Denied" with "Invalid Account". The log said `Permission denied for developer@cluster.local for check {...}`. |
| 5.2 | `can-i` `yes`. No approval page on the second login. `/` 200 "Hello World", `/whoami` `user=developer`. |
| 5.3 | After the removal, the old session still got 200. After `/oauth/sign_out`, 403. A new login got 403 at the callback. |
| Part 6 | The token had 1700 base64 characters, and `serviceAccountName` was `hello-nginx`. Part 5 repeated with the same results, and `client_id` still named `hello-oauth-proxy`. |
| Part 6 mismatch | 500 "Internal Error". The log said `error redeeming code ... got 400 from ".../oauth/token" {"error":"unauthorized_client",...}`. |
| Trusted CA (code exchange) | The exchange at the public OAuth route succeeded with the two `-openshift-ca` files. No x509 error. |

## Next steps

1. Run Part 8 to clean up, if it has not run yet: `oc delete project demo-rnd` and `oc delete group demo-rnd-members`.
2. Optional: run Part 5 in a real browser once, to see the pages that the `curl` script saw.
3. Optional: a test with a user from the `ldap-local` provider.
