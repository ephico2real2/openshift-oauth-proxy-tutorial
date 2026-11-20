# End-to-end test

`e2e.sh` tests who can open the page behind the oauth-proxy, against the live Route.
It logs in like a browser: it uses `curl` with a cookie jar, and it posts the real login form and the scope approval form.
Use it after a deploy with the manifests (README, step 4) or with the Helm chart (chart README, section 5).

## Files

| Path | What it does |
|---|---|
| `e2e.sh` | Runs the 14 checks and prints `PASS` or `FAIL` for each one. |
| `lib/login.sh` | The function `login USER PASSWORD JAR`. It logs a user in and prints the status of `/oauth/callback`: 302 admitted, 403 refused, 500 error. |

## What you need

1. `oc`, logged in as a cluster administrator. The test changes the group of the viewer.
2. `curl` and `bash` 3.2 or later (the macOS `/bin/bash` works).
3. The deploy and step 1 of the tutorial (the groups and their roles) are done.
4. Three users: a viewer, an editor and a user with no access.

## Run it

Give the passwords in the environment. They are never in a file of this repository:

```bash
export VIEWER_PASSWORD='...' EDITOR_PASSWORD='...' OUTSIDER_PASSWORD='...'
tests/e2e.sh
```

Expected result: 14 lines that start with `PASS`, then `RESULT: 0 failure(s)`, and exit status 0.

## Settings

Each setting is an environment variable. The defaults are the demo of the tutorial.

| Variable | Default | What it is |
|---|---|---|
| `NAMESPACE` | `demo-rnd` | The namespace of the page |
| `ROUTE` | `hello-nginx` | The Route of the page |
| `OAUTH_CLIENT` | `hello-oauth-proxy` | The OAuth client ServiceAccount |
| `IDP` | `ldap-local` | The identity provider of the test users |
| `VIEWER_USER` | `jane.smith` | A user in `VIEWER_GROUP` (role `view`) |
| `VIEWER_GROUP` | `demo-rnd-viewers` | The group of the viewer |
| `EDITOR_USER` | `john.doe` | A user with the role `edit` through a group |
| `OUTSIDER_USER` | `alice.cooper` | A user with no role in the namespace |
| `VIEWER_PASSWORD`, `EDITOR_PASSWORD`, `OUTSIDER_PASSWORD` | none | Required |

## The checks

| Check | Expected | Requirement |
|---|---|---|
| Not logged in: `/` | 403, the sign-in page | R1 |
| `/oauth/start` | 302 to the OAuth server | R1 |
| The `client_id` of the redirect | names `OAUTH_CLIENT` | R7 |
| `OUTSIDER_USER` logs in | 403 at `/oauth/callback` | R2 |
| `VIEWER_USER` logs in | 302, then `/` is 200, the page shows the user, and `/whoami` is `user=<viewer>` | R2, R3 |
| `EDITOR_USER` logs in | 302, and `/whoami` is `user=<editor>` | R3 |
| The viewer is removed from `VIEWER_GROUP` | The old session still gets 200 | 9.4 of the tutorial |
| The viewer signs out | 403 | 9.4 |
| The removed viewer logs in again | 403 at `/oauth/callback` | R2 |
| The viewer is put back, and logs in | 302 | R4 |

## Side effects

The test removes `VIEWER_USER` from `VIEWER_GROUP` for some seconds, then puts it back.
If the test stops early (a failure, Ctrl-C or `kill`), its exit trap puts the user back and prints `(put <user> back in <group>)`.
The session cookies are in a temporary directory, which the test deletes at the end.

## When a check fails

| Message | Cause |
|---|---|
| `Set the passwords of the test users in the environment` | A password variable is missing. Exit status 2. |
| `login: the identity provider refused <user>` | The user name or the password is wrong, or the user is not in `IDP`. |
| `login: /oauth/start did not redirect to the OAuth server` | The proxy is not ready, or the Route goes somewhere else. |
| `FAIL ... is refused (want: 403, got: 302)` | The user has access that you did not expect, for example a cluster-wide role (tutorial, 5.3). |
| `FAIL ... is admitted (want: 302, got: 403)` | The user is not in a group with a role in the namespace (tutorial, step 1). |

Measured on CRC (OpenShift 4.22.14) on 2026-11-20 with `/bin/bash` 3.2: 14 of 14 passed.
A wrong password gave the `refused` message and exit status 1.
A `kill` while the viewer was out of the group gave exit status 130, and the viewer was back in the group.
