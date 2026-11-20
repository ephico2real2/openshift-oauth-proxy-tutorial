# OpenShift oauth-proxy: a dedicated ServiceAccount and namespace-only access

This tutorial is for an engineer who runs an application behind the OpenShift oauth-proxy.
The oauth-proxy is a sidecar container that sends users to the cluster login page before it lets them reach the application.
You will build a small nginx "Hello World" page in the namespace `demo-rnd`.
Only members of `demo-rnd` can open the page.

When you complete it, you can do these things:

1. Explain each object that an oauth-proxy sidecar needs, and what each one does at login.
2. Make a dedicated ServiceAccount the OAuth client of the proxy, in two forms.
3. Make the two Red Hat CA ConfigMaps: the service CA (an annotation) and the trusted CA bundle (a label).
4. Write a SubjectAccessReview rule that admits only members of one namespace.
5. When a login fails, find the cause.

## Contents of this repository

| Path | What it holds |
|---|---|
| `manifests/base/` | The demo: the OAuth client ServiceAccount, the page, the two CA ConfigMaps, the Service, the Route, the Deployment and the RoleBinding for members. |
| `manifests/checks/tls-check-job.yaml` | A Job that verifies the proxy certificate with the injected service CA. |
| `manifests/option-b/` | The workload and the OAuth client use two ServiceAccounts. |
| `docs/HANDOVER.md` | The state of the work: what is measured and what is still to run. |

## Status of this tutorial

Each claim has one of three sources.
The status of each part follows.

| Part | Source | State on 2026-11-20 |
|---|---|---|
| The nginx container | `podman run` of `ubi9/nginx-124:1-1795128187` as UID 54321, group 0, read-only root | Measured. `/` returns 200 "Hello World". The pod IP refuses the connection. `/whoami` prints the forwarded user. |
| Proxy behavior | Source of `openshift/oauth-proxy` at commit `2c9e613` | Read from the source. |
| OAuth server behavior | Source of `openshift/oauth-server` (master) and `openshift/library-go` | Read from the source. |
| Parts 3 to 6 on a cluster | CRC | Not run yet. Run it on CRC and record the output here. |

## Part 1: How an oauth-proxy sidecar works

The demo makes these objects for the proxy.

| Object | What it sets | Why |
|---|---|---|
| ServiceAccount `hello-oauth-proxy` | Annotation `serviceaccounts.openshift.io/oauth-redirectreference.primary` that names the Route `hello-nginx` | The annotation makes the ServiceAccount an OAuth client. No OAuthClient object is necessary. |
| Service `hello-nginx` | Annotation `service.beta.openshift.io/serving-cert-secret-name: hello-nginx-tls`, and `targetPort: oauth-proxy` | The service-ca operator issues the proxy certificate. The Service sends traffic to the proxy, never to the application. |
| Route `hello-nginx` | `termination: reencrypt` | The router opens TLS to the proxy again and trusts the service CA. |
| ConfigMap `hello-nginx-trusted-ca` | Label `config.openshift.io/inject-trusted-cabundle: "true"`, no data | The Cluster Network Operator fills it with the trusted CA bundle. |
| Deployment `hello-nginx` | An `oauth-proxy` container in front of nginx on `127.0.0.1:8080` | The proxy does the login. nginx listens on loopback, so a call to the pod IP cannot bypass the proxy. |
| RoleBinding `demo-rnd-members-view` | The group `demo-rnd-members` gets `view` in `demo-rnd` | The members pass the access rule of the proxy. |

These are the proxy arguments that matter for this tutorial:

```text
-provider=openshift
-openshift-service-account=hello-oauth-proxy
-openshift-sar={"namespace":"demo-rnd","resource":"services","resourceName":"hello-nginx","verb":"get"}
-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
-openshift-ca=/etc/pki/ca-trust/injected/ca-bundle.crt
-cookie-expire=1h
```

Without `-openshift-sar`, any user who can log in to the cluster can open the page.

### The login, step by step

1. The browser opens the Route. The proxy finds no session cookie and returns its sign-in page with status 403 (`oauthproxy.go`, `OAuthProxy.Proxy`).
2. The user clicks "Log in with OpenShift". The proxy sends the browser to the cluster OAuth server with `client_id=system:serviceaccount:<namespace>:<serviceaccount>`.
3. The user logs in. On the first login, the OAuth server asks the user to approve the scopes `user:info user:check-access` (`provider.go`, `LoadDefaults`).
4. The OAuth server sends the browser back to `/oauth/callback`. The OAuth server accepts this callback because the ServiceAccount annotation names the Route.
5. The proxy exchanges the code for a user token at the public OAuth route. The client secret is the ServiceAccount token. The proxy must trust the CA of the OAuth route for this call.
6. If `-openshift-sar` is set, the proxy sends a SubjectAccessReview with the token of the user (`provider.go`, `ReviewUser`). The proxy needs no RBAC for it.
7. If the review is refused, the user gets 403 "Permission Denied" and "Invalid Account" (`oauthproxy.go`, `OAuthCallback`).
8. If the review is allowed, the proxy sets a signed cookie and forwards each request with the header `X-Forwarded-User`.

The proxy runs the review once, at login (`oauthproxy.go`, `redeemCode`).
A user who loses access keeps the session until the cookie expires or the user signs out at `/oauth/sign_out`.
If access changes often, keep `-cookie-expire` short.

## Part 2: The design choices

### 2.1 A dedicated ServiceAccount as the OAuth client

`-openshift-service-account=NAME` sets the client ID to `system:serviceaccount:<pod namespace>:NAME`.
It reads the client secret from the token that the pod mounts, at `/var/run/secrets/kubernetes.io/serviceaccount/token` (`provider.go`, `LoadDefaults`).
The proxy reads that file once, at start.

The OAuth server accepts a client secret in two cases (`oauth-server` `storage.go`, `clientWrapper.ClientSecretMatches`, and `library-go` `oauthclientregistry.go`, `getServiceAccountTokens`):

1. The secret is the token of a Secret of type `kubernetes.io/service-account-token` for that ServiceAccount.
2. The secret is a JWT, and a TokenReview of it returns the user name of that ServiceAccount.

The pod token is a JWT of the pod ServiceAccount.
So the name in `-openshift-service-account` and the `serviceAccountName` of the pod must be the same ServiceAccount.
That gives two forms of a dedicated ServiceAccount.

Option A: the pod runs as the dedicated ServiceAccount.
If the application does not call the Kubernetes API, use this option. nginx does not call it.
The ServiceAccount `hello-oauth-proxy` has the redirect annotation and no RoleBinding.
Part 3 deploys this option, from `manifests/base/`.

Option B: two ServiceAccounts in one pod.
If the application calls the Kubernetes API with its own RBAC, use this option.
The pod runs as the workload ServiceAccount.
The proxy uses `-client-id=system:serviceaccount:demo-rnd:hello-oauth-proxy` and `-client-secret-file` with a token Secret of the client ServiceAccount.
The client secret then carries no RBAC of the application.
The cost is a token that does not expire, which you revoke by deleting the Secret.
A token from `oc create token` also matches case 2, but it expires, and the proxy reads the file only at start.
Part 6 changes the demo to this option, from `manifests/option-b/`.

### 2.2 The two CA ConfigMaps

OpenShift fills two kinds of ConfigMap with CA certificates.
You create them empty, and an operator writes the data.

| ConfigMap | How you ask for it | Key that OpenShift writes | Content | Use in this tutorial |
|---|---|---|---|---|
| `hello-nginx-service-ca` | Annotation `service.beta.openshift.io/inject-cabundle: "true"` | `service-ca.crt` | The service CA. It signs every serving certificate from the service-ca operator. | A client in the cluster verifies `https://hello-nginx.demo-rnd.svc`. |
| `hello-nginx-trusted-ca` | Label `config.openshift.io/inject-trusted-cabundle: "true"` | `ca-bundle.crt` | The system trust store and the CAs in `proxy/cluster` `spec.trustedCA`. | An extra `-openshift-ca` for the proxy. If a corporate CA signs `*.apps`, the code exchange at the public OAuth route needs it. |

The first one is an annotation and the second one is a label.
If you use the wrong field, OpenShift writes nothing and gives no error.
Every namespace also has a ConfigMap `openshift-service-ca.crt` with the same service CA.

`-openshift-ca` can be given more than one time.
When you give it, it replaces the default (`provider.go`, `newOpenShiftClient`).
So the Deployment names the ServiceAccount `ca.crt` again, next to the trusted bundle.

### 2.3 The access rule for namespace members

A member of `demo-rnd` is a user with a RoleBinding in `demo-rnd`, directly or through a group.
The roles `view`, `edit` and `admin` all grant `get` on Services.
So the rule admits a user who can get the Service `hello-nginx` in `demo-rnd`:

```json
{"namespace":"demo-rnd","resource":"services","resourceName":"hello-nginx","verb":"get"}
```

This is the rule that the upstream README shows, in the section on `--openshift-sar=JSON`.
A JSON array of rules requires all of them.

A SubjectAccessReview asks "can this user do this?", and cluster-wide roles answer it too.
So `cluster-admin`, `cluster-reader` and any other ClusterRoleBinding that grants `get services` also pass.
No SubjectAccessReview can exclude them.
For "members only", that is the closest rule that RBAC can express.

The manifest `manifests/base/50-rolebinding-members.yaml` binds the group `demo-rnd-members` to `view`.
You manage membership in the group, not in the RoleBinding.
If `oc adm groups sync` fills groups from LDAP, the group can come from LDAP.

## Part 3: Deploy the demo

You need these things:

1. `oc` logged in as a cluster administrator. On CRC, this is `kubeadmin`.
2. A second user with no rights in `demo-rnd`. On CRC, this is `developer`, password `developer`.
3. A pull secret for `registry.redhat.io` in the global pull secret. CRC has one.
4. A clone of this repository. Run the commands from the repository root.

Create the project:

```bash
oc new-project demo-rnd
```

Create the cookie secret.
The proxy signs the session cookie with it.
Keep it out of git:

```bash
oc -n demo-rnd create secret generic hello-oauth-proxy-cookie \
  --from-literal=session_secret="$(openssl rand -base64 32 | tr -d '\n')"
```

Apply the base manifests:

```bash
oc apply -f manifests/base/
oc -n demo-rnd rollout status deployment/hello-nginx --timeout=120s
```

Expected result: `deployment "hello-nginx" successfully rolled out`, and the pod shows `2/2` in `oc -n demo-rnd get pods`.

## Part 4: Make sure that the certificates are in place

Make sure that the service-ca operator issued the proxy certificate:

```bash
oc -n demo-rnd get secret hello-nginx-tls -o jsonpath='{.type}{"\n"}'
```

Expected result: `kubernetes.io/tls`.

Make sure that both CA ConfigMaps have data:

```bash
oc -n demo-rnd get configmap hello-nginx-service-ca \
  -o jsonpath='{.data.service-ca\.crt}' | grep -c 'BEGIN CERTIFICATE'
oc -n demo-rnd get configmap hello-nginx-trusted-ca \
  -o jsonpath='{.data.ca-bundle\.crt}' | grep -c 'BEGIN CERTIFICATE'
```

Expected result: a number of 1 or more for the service CA, and a much larger number for the trusted bundle.
If a count is 0, the annotation or the label is on the wrong field. Read Part 2.2.

Run the TLS check Job.
It calls the proxy through the Service and verifies its certificate with the injected service CA:

```bash
oc apply -f manifests/checks/tls-check-job.yaml
oc -n demo-rnd wait --for=condition=complete job/hello-nginx-tls-check --timeout=60s
oc -n demo-rnd logs job/hello-nginx-tls-check
```

Expected result: `OK`, the body of `/oauth/healthz` (`oauthproxy.go`, `PingPage`).

## Part 5: Test the access rule

Get the host of the Route, and the CA of the default ingress certificate for `curl`:

```bash
HOST="$(oc -n demo-rnd get route hello-nginx -o jsonpath='{.status.ingress[0].host}')"
oc -n openshift-config-managed get configmap default-ingress-cert \
  -o jsonpath='{.data.ca-bundle\.crt}' > /tmp/ingress-ca.crt
echo "${HOST}"
```

Make sure that an anonymous request gets the sign-in page and not the content:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --cacert /tmp/ingress-ca.crt "https://${HOST}/"
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --cacert /tmp/ingress-ca.crt "https://${HOST}/oauth/start"
```

Expected result: `403` for the first command.
For the second command, `302` and a URL on the OAuth server that contains `client_id=system%3Aserviceaccount%3Ademo-rnd%3Ahello-oauth-proxy`.

### 5.1 A user who is not a member is refused

Ask the cluster the same question that the proxy asks, as `developer`:

```bash
oc login -u developer -p developer
oc auth can-i get service/hello-nginx -n demo-rnd
```

Expected result: `no`.

Open `https://<HOST>/` in a private browser window and log in as `developer`.
If the OAuth server asks, approve the scopes.
Expected result: the page "Permission Denied" with "Invalid Account".
The proxy log shows the refusal:

```bash
oc login -u kubeadmin
oc -n demo-rnd logs deployment/hello-nginx -c oauth-proxy | grep 'Permission Denied'
```

### 5.2 A member is admitted

Add `developer` to the group of members:

```bash
oc adm groups new demo-rnd-members developer
oc login -u developer -p developer
oc auth can-i get service/hello-nginx -n demo-rnd
```

Expected result: `yes`.
If the group already exists, use `oc adm groups add-users demo-rnd-members developer`.

Open a new private window and log in as `developer` again.
Expected result: "Hello World".
Open `https://<HOST>/whoami`.
Expected result: `user=developer`.

### 5.3 A removed member keeps the session until it expires

Remove `developer` from the group as `kubeadmin`:

```bash
oc login -u kubeadmin
oc adm groups remove-users demo-rnd-members developer
```

Reload the page in the window that is signed in.
Expected result: the page still loads, because the review ran only at login.
Open `https://<HOST>/oauth/sign_out`, then log in again.
Expected result: "Permission Denied".
Without the sign-out, the session ends after `-cookie-expire=1h`.

## Part 6: Option B, a separate OAuth client ServiceAccount

Apply the variant over the base.
It adds the workload ServiceAccount `hello-nginx` and the token Secret, and it replaces the Deployment:

```bash
oc apply -f manifests/option-b/
oc -n demo-rnd rollout status deployment/hello-nginx --timeout=120s
```

Make sure that the token controller filled the Secret, and that the pod runs as the workload ServiceAccount:

```bash
oc -n demo-rnd get secret hello-oauth-proxy-token -o jsonpath='{.data.token}' | wc -c
oc -n demo-rnd get pods -l app=hello-nginx -o jsonpath='{.items[0].spec.serviceAccountName}{"\n"}'
```

Expected result: a number much larger than 0, then `hello-nginx`.
Repeat Part 5.
The results are the same, and the `client_id` in the `/oauth/start` redirect still names `hello-oauth-proxy`.

To see why the two must agree, edit the Deployment with `oc -n demo-rnd edit deployment hello-nginx`.
Remove `-client-id` and `-client-secret-file`, and add `-openshift-service-account=hello-oauth-proxy` again, with the pod still on `hello-nginx`.
The client secret is then the token of `hello-nginx`, and the OAuth server refuses the code exchange.
Expected result: "Internal Error" after login, and `error redeeming code` in the proxy log.

## Part 7: Troubleshooting

| What you see | Cause | What to do |
|---|---|---|
| "Internal Error" after login, and `error redeeming code` with `x509: certificate signed by unknown authority` in the proxy log | The proxy does not trust the CA of the public OAuth route. | Make sure that `hello-nginx-trusted-ca` has data and is mounted, and that `-openshift-ca` names both files. |
| "Internal Error" after login, and `error redeeming code` without x509 | The client secret is not a token of the client ServiceAccount. | Make sure that `serviceAccountName` matches `-openshift-service-account`, or use Option B. |
| "Permission Denied" and "Invalid Account" | The SubjectAccessReview refused the user. | Run `oc auth can-i get service/hello-nginx -n demo-rnd` as that user. |
| The OAuth server refuses the request with `invalid_request` or a redirect error | The redirect annotation names a Route that does not exist, or the Route has no admitted host. | Make sure that the annotation names `hello-nginx` and that `oc get route hello-nginx` shows a host. |
| The pod stays in `ContainerCreating` | A Secret or ConfigMap that the pod mounts does not exist yet. | Run `oc -n demo-rnd describe pod -l app=hello-nginx` and create the missing object. The cookie secret is the usual one. |
| `ImagePullBackOff` on the proxy | The node cannot pull from `registry.redhat.io`. | Add the registry to the global pull secret, or use a mirror. |
| A user removed from the group still sees the page | The review runs only at login. | Sign the user out at `/oauth/sign_out`, or wait for `-cookie-expire`. |

## Part 8: Clean up

Delete the project and the group as `kubeadmin`:

```bash
oc delete project demo-rnd
oc delete group demo-rnd-members
```

## Sources

1. `openshift/oauth-proxy` at commit `2c9e613ae807baecb5bbeeb47b567b2e6c47a088`: the README, `main.go`, `options.go`, `oauthproxy.go`, `providers/openshift/provider.go`, `contrib/sidecar.yaml`.
2. `openshift/oauth-server` master: `pkg/oauthserver/auth.go`, `pkg/osinserver/registrystorage/storage.go`.
3. `openshift/library-go` master: `pkg/oauth/oauthserviceaccountclient/oauthclientregistry.go`.
