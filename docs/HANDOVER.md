# Handover

This note gives the state of the work, so that the next session can continue without the conversation that wrote it.
Update it after each work session.

## State on 2026-11-20 (second session)

The tutorial and the Helm chart are complete, and both are tested end to end on CRC.

| Item | State | Evidence |
|---|---|---|
| `README.md` | Rewritten in simple English, with a requirements table (R1 to R11). Each expected result is measured. | markdownlint: 0 errors |
| `manifests/` | Access is no longer in the manifests: `50-rolebinding-members.yaml` is removed. A cluster administrator binds groups (step 1). The page shows the signed-in user with nginx SSI. | Deployed on CRC, 14 login checks passed for Option A and Option B |
| `helm-chart/` | Chart `hello-oauth-proxy` 0.1.0. It renders the same application objects as `manifests/`. It adds Helm labels, a `checksum/content` annotation, the cookie Job and the `helm test` pod. | `helm lint`, a semantic diff of each object, and installs on CRC |
| Screenshots | `helm-chart/docs/images/`, taken with Google Chrome through Playwright | 2026-11-20 |

## The cluster

CRC 2.64.0, OpenShift 4.22.14, Helm 4.3.1.

- The CRC API timed out under host memory pressure (swap 8.2 of 9.2 GB used). CRC was stopped, `crc config set enable-cluster-monitoring false` was set, and CRC was started again.
- That config value does not remove monitoring from an existing instance. Red Hat's docs say that only `crc delete` does, and that deletes the cluster with its LDAP setup, so it was not done.
- Instead, monitoring was turned off in a way that you can undo:
  1. A ClusterVersion override marks `openshift-monitoring/cluster-monitoring-operator` as unmanaged.
  2. All monitoring Deployments and StatefulSets are scaled to 0, except `metrics-server`.
  3. The `node-exporter` DaemonSet has the nodeSelector `crc.disabled/monitoring: "true"`.
- It freed 645m CPU and 2339 MiB.
- To turn monitoring on again, remove that override from `clusterversion/version` `spec.overrides`. The operator then restores the rest.

The state that is running now:

1. The groups `demo-rnd-viewers` (`jane.smith`) and `demo-rnd-editors` (`john.doe`), bound to `view` and `edit` in `demo-rnd`.
2. The Helm release `hello` in `demo-rnd`, with `serviceAccounts.oauthClient.create=false` and `cookieSecret.createWithJob=false`. The release has no ServiceAccount, Role or RoleBinding, in its objects or its hooks.
3. The ServiceAccount `hello-oauth-proxy`, applied from `helm-chart/examples/serviceaccount-oauth-client.yaml`, and the cookie Secret `hello-oauth-proxy-cookie`. Both are outside the release.

The LDAP test users are `jane.smith`, `john.doe` and `alice.cooper` (identity provider `ldap-local`).
Their lab passwords are in the README of the LDAP lab, `group-sync-operator-helm-chart/setup-local-ldap-testing/README.md`, section "Test logins".
None of these users has a ClusterRoleBinding.

## Measured on CRC

| Test | Result |
|---|---|
| Step 1 proof | `oc get groups` and `rolebindings -o wide` show groups only. `can-i '*' '*' --all-namespaces` is `no` for each user. |
| Manifests, Option A and Option B | 14 of 14 login checks passed: anonymous 403, `alice.cooper` refused, `jane.smith` (view) and `john.doe` (edit) admitted, removed member kept the session until sign-out. |
| Bypass | Port 8080 on the pod IP refused, port 8443 answered 403. |
| Helm install, `helm test` | `deployed` in 41 s with cached images. `helm test`: `Succeeded`, `OK`. |
| Helm upgrade | The cookie key hash stayed the same. An old session still got 200 after the pod restarted. The CA ConfigMaps kept their data. |
| Cookie Job | It created a 44-character key (32 bytes). On upgrade it logged `exists. It is kept.` The `hook-succeeded` policy deleted the Job and its RBAC after the hook phase. |
| Existing ServiceAccounts | With `create=false`, the release has no ServiceAccount. 14 of 14 passed, also with Option B. |
| Error cases | A missing ServiceAccount gives a `FailedCreate` event. A missing cookie Secret gives `FailedMount`. Just after an install, the Route can answer 503 for some seconds. |

## Review

Codex (`gpt-6.2-astra`) reviewed the work in a read-only sandbox.
It confirmed 8 of the 10 claims, refuted parts of 3, and gave 11 findings.

Accepted and fixed (all measured on CRC where possible):

- Key rotation needs `rollout restart`. Measured: an old session still got 200 after a new key, and 403 after the restart.
- The old RoleBinding `demo-rnd-members-view` needs a migration step.
- `helm upgrade` needs `--reuse-values`. Measured: `create=false` is kept.
- The restricted-team install needs `createWithJob=false`, checked with `helm get hooks`.
- Option A token life is now documented. Measured: 365 days.
- A warning about switching `create` from true to false on an installed release.
- Exact access wording.
- Cross-references, the parity wording and the "log back in" step.
- The Job uses `--ignore-not-found`.
- A `fail` when both ServiceAccounts have the same name.
- An accurate checksum comment.

A second Codex pass marked 9 of the 12 fixes as fixed, and found 4 gaps in the new text. All 4 are fixed now:

- Rotation is complete only after `rollout status` and when the old pod is gone.
- On a rename with `createWithJob=false`, the administrator creates the new cookie Secret first.
- The title and the intro now say exactly who passes the check.
- Restart the pod before the token expires, also with the one-year token life.

The second pass also refuted my reason for declining the quoting finding: `true` is a valid DNS label.
So the values that stand alone in the templates are now quoted. With `--set-string name=true`, each name field renders as a string.

Declined: a multi-line `page.title`. It is a one-line heading, and Codex agreed that this is a reasonable limit.

After these fixes, the chart was tested on CRC again. A new install's Job created the key, and `helm test` succeeded. The upgraded release passed 14 of 14 login checks.

## Next steps

1. If wanted, turn monitoring on again (see above).
2. Optional: test a user who has only a cluster-wide role, to show 5.3 of the README (cluster roles also pass).
