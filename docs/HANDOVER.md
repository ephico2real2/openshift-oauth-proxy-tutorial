# Handover

This note gives the state of the tutorial, so that the next session can continue without the conversation that wrote it.
Update it after each work session.

## State on 2026-11-20

The tutorial is complete as text, and Parts 3 to 6 have not run on a cluster.

| Item | State | Evidence |
|---|---|---|
| `README.md`, the tutorial | Written. markdownlint: 0 issues. | `markdownlint-cli2 README.md docs/HANDOVER.md` |
| `manifests/` | Each file parses as YAML. The `-openshift-sar` value and the redirect annotation parse as JSON. | `yq` and `jq` over every file |
| nginx configuration | Measured with `podman run` of `registry.access.redhat.com/ubi9/nginx-124:1-1795128187` as UID 54321, group 0, with a read-only root. `/` returned 200 "Hello World". A connection to the container IP was refused. `/whoami` printed the value of `X-Forwarded-User`. | Local run, 2026-11-19 |
| Option B Deployment | `manifests/option-b/41-deployment.yaml` equals the base Deployment with a strategic merge patch that changes the identity. Measured with `oc patch --local`. Only comments and list order differ. | `oc` 4.22.18, 2026-11-20 |
| Proxy and OAuth server behavior | Read from the source, not measured. | The Sources section of `README.md` |
| Parts 3 to 6 on CRC | Not run. | None yet |

## Next steps

1. On a machine with CRC, log in as `kubeadmin` and run Parts 3 to 6 of `README.md` in order.
2. Record each command output in the status table of `README.md`, with the date and the OpenShift version from `oc version`.
3. If an expected result differs, fix the manifest or the text, and write the measured output here.
4. Run Part 8 to clean up.

## Points to make sure of on the cluster

1. The image `registry.redhat.io/openshift4/ose-oauth-proxy-rhel9:v4.15` pulls on the CRC version in use. If the pull fails, use the tag that matches the CRC version.
2. The trusted CA bundle mounts at `/etc/pki/ca-trust/injected/ca-bundle.crt`, and the code exchange at the public OAuth route succeeds with it. If it fails, the symptom is the `x509` row of the troubleshooting table.
3. The `client_id` in the `/oauth/start` redirect names `hello-oauth-proxy` in both options.
4. A removed member keeps the session until sign-out or until `-cookie-expire=1h` (Part 5.3).
