# Complete CI/CD & DevSecOps Homework — Session 17

Bibek Jyoti Charah — 24bcs10112 (GitHub: SammyUrfen)

Environment: the pipeline runs on GitHub Actions (`ubuntu-latest` runners). Kubernetes is a throw-away
kind cluster (`helm/kind-action`, Kubernetes v1.35.0, kubectl v1.35.0) that the deploy job creates on the
runner, so no local cluster was used. Local checks (Bandit, pip-audit, pytest) ran on Fedora with `uvx`.
Tool versions: Bandit 1.9.4, pip-audit (latest), gitleaks 8.28.0, Trivy 0.75.0. All output is pasted as
printed. Long output is cut with `...`.

Repository: https://github.com/SammyUrfen/devops-session-17-devsecops

## The flow

```
Code → Build → Unit Test → SAST → SCA → Secret Scan → Docker Build → Image Scan → Security Gate → Push Image → Deploy to K8s
```

One workflow file, `.github/workflows/devsecops.yml`, runs on every push to any branch. Each stage is a
job (or a named step) that `needs:` the one before it. So a failure stops everything after it.
Push and deploy run only on `main`. Other branches get every check but never ship.

| # | Stage | Tool | What it checks | Fails the run when |
|---|---|---|---|---|
| 1 | Build | `pip` + `python -m compileall` | deps install, every `.py` file compiles | install or syntax error |
| 2 | Unit test | pytest + pytest-cov | 8 API tests, coverage report | any test fails |
| 3 | SAST | Bandit | the app source code for insecure patterns | a HIGH severity issue |
| 4 | SCA | pip-audit | pinned PyPI deps against the PyPA/OSV advisory DB | any known vulnerability |
| 5 | Secret scan | gitleaks | the whole git history (`fetch-depth: 0`) | any secret match |
| 6 | Docker build | `docker build` | builds `ghcr.io/sammyurfen/devops-session-17-devsecops:<sha>` | build error |
| 7 | Image scan | Trivy | OS packages + Python packages inside the image | never (report only) |
| 8 | Security gate | Trivy `--exit-code 1` | HIGH/CRITICAL CVEs that have a fix | one or more found |
| 9 | Push image | `docker push` with `GITHUB_TOKEN` | pushes `:<sha>` and `:latest` to GHCR | push error |
| 10 | Deploy | kind + kubectl | apply manifests, `rollout status`, curl the Service | rollout or curl fails |

Every scan uploads its report as an artifact: `test-report` (JUnit XML), `sast-bandit` (JSON),
`sca-pip-audit` (JSON), `secrets-gitleaks` (SARIF), `image-scan-trivy` (JSON + table). The upload step
uses `if: always()`, so the report is there even when the gate fails.

## Files

| Path | Purpose |
|---|---|
| `app/`, `tests/` | Flask "DevSecOps Dashboard" app and its 8 tests, copied from the course `demo/` |
| `requirements.txt`, `requirements-dev.txt` | runtime deps (Flask) and test deps (pytest, pytest-cov) |
| `Dockerfile` | `python:3.12-alpine`, no pip at run time, runs as UID 10001 |
| `k8s/deployment.yaml`, `k8s/service.yaml` | 2 replicas + NodePort Service |
| `.github/workflows/devsecops.yml` | the pipeline |
| `.gitleaks.toml` | gitleaks config: all default rules, no allow-list |
| `.trivyignore` | empty on purpose (see "The security gate threshold") |

## The stages

### 1–2. Build and unit test

Build installs `requirements-dev.txt` and compiles every Python file. A syntax error fails here, before
any test runs. The test job runs pytest with coverage and writes `reports/junit.xml`.

### 3. SAST — Bandit

SAST reads the source code without running it. Bandit knows Python-specific risks: `eval`, `pickle`,
`subprocess` with `shell=True`, Flask debug mode, weak random, and more. The job runs Bandit twice. The
first run reports every severity and never fails. The second run (`--severity-level high`) is the gate.

Bandit found a real HIGH issue in the course demo. I ran it locally before I wrote the pipeline:

```
$ bandit -r app
...
>> Issue: [B201:flask_debug_true] A Flask app appears to be run with debug=True, which exposes the Werkzeug debugger and allows the execution of arbitrary code.
   Severity: High   Confidence: Medium
   CWE: CWE-94 (https://cwe.mitre.org/data/definitions/94.html)
   Location: app/app.py:234:4
233	if __name__ == "__main__":
234	    app.run(host="0.0.0.0", port=5001, debug=True)
--------------------------------------------------
>> Issue: [B104:hardcoded_bind_all_interfaces] Possible binding to all interfaces.
   Severity: Medium   Confidence: Medium
   Location: app/app.py:234:17
...
	Total issues (by severity):
		Undefined: 0
		Low: 5
		Medium: 1
		High: 1
```

Fix in `app/app.py`: debug mode is now off unless `FLASK_DEBUG=1` is set. The Werkzeug debugger lets
anyone who reaches the page run Python code, so it must never be on in a container. The bind to
`0.0.0.0` stays, with `# nosec B104` and a comment: a container must listen on all interfaces, or the
Service cannot reach it. The 5 LOW findings are B311 (`random` is not a crypto RNG). The app uses
`random` only to pick a greeting and to fake pipeline timings, so LOW is correct and they do not gate.

### 4. SCA — pip-audit

SCA checks the third-party packages, not my code. pip-audit resolves `requirements-dev.txt` (which
includes `requirements.txt`) and looks up each version in the PyPI advisory database. It found a real
issue in the course demo's test deps:

```
$ pip-audit -r requirements-dev.txt
Found 2 known vulnerabilities in 1 package
Name   Version ID              Fix Versions
------ ------- --------------- ------------
pytest 8.4.2   PYSEC-2026-1845 9.0.3
pytest 8.4.2   PYSEC-2026-1845 9.0.3
```

Fix: `pytest==9.0.3` and `pytest-cov==7.0.0` (the version that supports pytest 9). After the bump:
`No known vulnerabilities found`. pytest only runs in CI, not in the image, but it still runs code on
the CI runner, so I fixed it rather than excusing it.

### 5. Secret scan — gitleaks

gitleaks matches regexes plus an entropy check for API keys, tokens and private keys. The checkout uses
`fetch-depth: 0`, so gitleaks scans every commit. A secret that was added and then deleted in a later
commit is still in history, and still leaked. `--redact` keeps the secret out of the CI log.
`.gitleaks.toml` extends the default rule set and allow-lists nothing.

### 6–8. Docker build, image scan, security gate

The image is built once and tagged with the commit SHA. Trivy then scans it twice:

1. Step 7, full report: every severity, JSON + table, never fails. This is the record.
2. Step 8, the gate: `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1`.

#### The security gate threshold

| Finding | Gate result | Why |
|---|---|---|
| CRITICAL or HIGH, fix available | **fail** | I can act on it now: bump the package or the base image |
| CRITICAL or HIGH, no fix released | pass, but listed in the step 7 report | no version exists to move to. Failing would block every deploy with nothing to do |
| MEDIUM / LOW | pass, listed in the report | handled in normal upgrades. Gating on them makes the gate noisy and people start ignoring it |

Bandit uses the same line (HIGH fails). pip-audit is stricter (any known vulnerability fails), because
a Python dependency bump is cheap. gitleaks fails on any match, because one leaked key is enough.

`.trivyignore` is empty. A CVE goes in it only with a written reason (for example, the vulnerable code
path is not reachable). In this repo no CVE needed that.

#### Base image fix

The course `Dockerfile` used `python:3.12-slim`. The run below is the first green run with that base:

```
Total: 163 (LOW: 61, MEDIUM: 58, HIGH: 44, CRITICAL: 0)      ← debian 13.7 OS packages
Total: 6 (LOW: 1, MEDIUM: 5, HIGH: 0, CRITICAL: 0)           ← pip 25.0.1
```

All 44 HIGH are in Debian packages with no fix yet (`util-linux`, `ncurses`, `libsystemd0`,
`perl-base`, ...). So the gate passed, but I did not want to ship 44 HIGH CVEs. The app needs none of
those packages. I took two steps:

| Change | Result |
|---|---|
| `python:3.12-slim` → `python:3.12-alpine` | OS findings 163 → 1 (one MEDIUM in zlib) |
| upgrade pip in the image | gate **failed**: 4 fixable HIGH in "Python" (see below) |
| instead: `pip uninstall -y pip` and delete `ensurepip/` after the deps install | 0 HIGH, 0 CRITICAL, gate passes |

The failing run with Alpine + upgraded pip (run 37639688724, step 8):

```
Total: 4 (HIGH: 4, CRITICAL: 0)
...
│ msgpack    │ GHSA-6v7p-g79w-8964 │ HIGH     │ fixed  │ 1.1.2             │ 1.2.1         │ MessagePack for Python: Out-of-bounds read / crash on        │
│ setuptools │ CVE-2025-47273      │          │        │ 70.3.0            │ 78.1.1        │ setuptools: Path Traversal Vulnerability in setuptools       │
│ urllib3    │ CVE-2026-97687      │ HIGH     │        │ 2.7.0             │ 2.8.0         │ urllib3: urllib3: Traffic interception via HTTPS proxy TLS   │
│            │ CVE-2026-97689      │          │        │                   │               │ urllib3: urllib3: Denial of Service via unbounded memory     │
...
##[error]Process completed with exit code 1.
```

None of these are app deps. A local `docker run` of that image showed that `ensurepip/_bundled/` still
held `pip-25.0.1-py3-none-any.whl`. I believe Trivy found the vendored libraries in that wheel, because
these HIGH findings went away when I deleted `ensurepip/` (inferred, not proven per-file). The app never runs pip
at run time, so removing pip is the smaller and safer fix. Final image scan (run 37640171039):

```
ghcr.io/sammyurfen/devops-session-17-devsecops:eedd9f0f5cd1014d63843c054b962b209770ce77 (alpine 3.24.2)
Total: 1 (LOW: 0, MEDIUM: 1, HIGH: 0, CRITICAL: 0)
│ zlib    │ CVE-2026-85091 │ MEDIUM   │ fixed  │ 1.3.2-r0          │ 1.3.2-r1      │ zlib versions 1.3.1.2 through 1.3.2 contain a heap buffer │
...
│ usr/local/lib/python3.12/site-packages/flask-3.1.3.dist-info/METADATA            │ python-pkg │        0        │    -    │
...
│ usr/local/lib/python3.12/site-packages/werkzeug-3.1.9.dist-info/METADATA         │ python-pkg │        0        │    -    │
```

The zlib MEDIUM has a fix in the Alpine repo. It is below the gate line, and the next
`python:3.12-alpine` rebuild will pick it up.

The image also runs as a non-root user (UID 10001), and the Deployment sets `runAsNonRoot: true` and
`allowPrivilegeEscalation: false`.

### 9. Push to GHCR

The `image` job has `permissions: packages: write`. It logs in to `ghcr.io` with the built-in
`GITHUB_TOKEN` (no personal token is stored) and pushes two tags: the commit SHA (immutable, used by
the deploy) and `latest`. This step has `if: github.ref == 'refs/heads/main'`, and it runs only after
the gate step in the same job has passed.

### 10. Deploy to Kubernetes

`helm/kind-action` starts a one-node kind cluster inside the runner. Then the job:

1. Creates a `docker-registry` Secret `ghcr-pull` from `GITHUB_TOKEN` (`packages: read`). New GHCR
   packages are private, so the kubelet needs credentials to pull.
2. Replaces `__IMAGE__` in `k8s/deployment.yaml` with `ghcr.io/sammyurfen/devops-session-17-devsecops:<sha>`.
   So the cluster runs the exact image that passed the scans, not whatever `latest` is.
3. `kubectl apply -f k8s/` and `kubectl rollout status --timeout=180s`.
4. curls the NodePort (`<node-ip>:30001`) from the runner: `/health` and `/api/greet/Bibek`.

The manifests:

- `deployment.yaml`: 2 replicas, `imagePullSecrets: ghcr-pull`, a readiness probe on `/health`
  (rollout waits until both Pods answer), requests 50m/64Mi and limits 250m/256Mi, non-root.
- `service.yaml`: `NodePort` 30001 → container port 5001, selected by `app: session17-python`.

## Real runs

```
$ gh run list
completed	failure	Use a base32-shaped fake AWS key ID	DevSecOps pipeline	demo-leak	push	37641017962	1m28s	2026-10-07T14:57:17Z
completed	success	Add fake AWS key to test the secret scan gate	DevSecOps pipeline	demo-leak	push	37640697127	1m53s	2026-10-07T14:54:49Z
completed	success	Remove pip from the runtime image to clear fixable HIGH CVEs	DevSecOps pipeline	main	push	37640171039	3m19s	2026-10-07T14:51:02Z
completed	failure	Switch base image to python:3.12-alpine and upgrade pip	DevSecOps pipeline	main	push	37639688724	2m16s	2026-10-07T14:47:36Z
completed	success	Install Trivy from its apt repository	DevSecOps pipeline	main	push	37639084495	3m27s	2026-10-07T14:43:21Z
completed	failure	Add DevSecOps pipeline for the Flask demo app	DevSecOps pipeline	main	push	37638726418	1m57s	2026-10-07T14:40:47Z
```

### The green run: every job and step

```
$ gh run view 37640171039 --verbose
✓ main DevSecOps pipeline · 37640171039
Triggered via push about 8 minutes ago

JOBS
✓ 1. Build in 11s (ID 112856702322)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Run actions/setup-python@v5
  ✓ Run pip install -r requirements-dev.txt
  ✓ Compile all Python files
  ✓ Post Run actions/setup-python@v5
  ✓ Post Run actions/checkout@v4
  ✓ Complete job
✓ 2. Unit test in 9s (ID 112856824831)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Run actions/setup-python@v5
  ✓ Run pip install -r requirements-dev.txt
  ✓ Run pytest -v --cov=app --cov-report=term --junitxml=reports/junit.xml
  ✓ Run actions/upload-artifact@v4
  ✓ Post Run actions/setup-python@v5
  ✓ Post Run actions/checkout@v4
  ✓ Complete job
✓ 3. SAST (Bandit) in 13s (ID 112856936526)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Run actions/setup-python@v5
  ✓ Run pip install bandit==1.9.4
  ✓ Full report (all severities, never fails)
  ✓ Gate - fail on HIGH severity
  ✓ Run actions/upload-artifact@v4
  ✓ Post Run actions/setup-python@v5
  ✓ Post Run actions/checkout@v4
  ✓ Complete job
✓ 4. SCA (pip-audit) in 22s (ID 112857072421)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Run actions/setup-python@v5
  ✓ Run pip install pip-audit
  ✓ Audit pinned dependencies (fails on any known vulnerability)
  ✓ Run actions/upload-artifact@v4
  ✓ Post Run actions/setup-python@v5
  ✓ Post Run actions/checkout@v4
  ✓ Complete job
✓ 5. Secret scan (gitleaks) in 8s (ID 112857310122)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Install gitleaks
  ✓ Scan history
  ✓ Run actions/upload-artifact@v4
  ✓ Post Run actions/checkout@v4
  ✓ Complete job
✓ 6-9. Docker build, image scan, gate, push in 49s (ID 112857428323)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ 6. Docker build
  ✓ Install Trivy (official apt repository)
  ✓ 7. Image scan - full report (all severities, never fails)
  ✓ 8. Security gate - fail on fixable HIGH/CRITICAL
  ✓ Run actions/upload-artifact@v4
  ✓ 9. Push to GHCR (main only)
  ✓ Post Run actions/checkout@v4
  ✓ Complete job
✓ 10. Deploy to Kubernetes (kind) in 51s (ID 112857854454)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Run helm/kind-action@v1
  ✓ Run kubectl version && kubectl get nodes -o wide
  ✓ Pull Secret for GHCR
  ✓ Apply manifests with the image built in this run
  ✓ Smoke test through the Service
  - Debug on failure
  ✓ Post Run helm/kind-action@v1
  ✓ Post Run actions/checkout@v4
  ✓ Complete job

ANNOTATIONS
...

ARTIFACTS
sca-pip-audit
sast-bandit
test-report
image-scan-trivy
secrets-gitleaks
```

The annotations (cut) are GitHub notices that Node.js 20 actions are deprecated and that `ubuntu-latest`
moves to Ubuntu 26. They are warnings, not failures.

### Log excerpts per stage (run 37640171039, from `gh run view --log`)

1. Build:

```
build OK
```

2. Unit test:

```
tests/test_app.py::test_add_numbers_missing_fields PASSED                [ 62%]
tests/test_app.py::test_calculator_multiply PASSED                       [ 75%]
tests/test_app.py::test_calculator_divide_by_zero PASSED                 [ 87%]
tests/test_app.py::test_status PASSED                                    [100%]
...
Name              Stmts   Miss  Cover
-------------------------------------
app/__init__.py       0      0   100%
app/app.py          102     32    69%
-------------------------------------
TOTAL               102     32    69%
======================== 8 passed, 6 warnings in 0.17s =========================
```

The 6 warnings are `datetime.utcnow()` deprecation notices from the course app code.

3. SAST, gate step:

```
Run metrics:
	Total issues (by severity):
		Undefined: 0
		Low: 5
		Medium: 0
		High: 0
```

4. SCA:

```
No known vulnerabilities found
```

5. Secret scan:

```
INF 4 commits scanned.
INF scanned ~50925 bytes (50.92 KB) in 175ms
INF no leaks found
```

6. Docker build:

```
#12 naming to ghcr.io/sammyurfen/devops-session-17-devsecops:eedd9f0f5cd1014d63843c054b962b209770ce77 done
#12 DONE 0.7s
```

7–8. Image scan and gate: see "Base image fix" above. The gate step listed every target with `0`
and exited 0.

9. Push:

```
Login Succeeded
eedd9f0f5cd1014d63843c054b962b209770ce77: digest: sha256:c4ac1819336a15ef6984d5583c26abd5acef96183d81b74ac313842a7710d989 size: 2197
latest: digest: sha256:c4ac1819336a15ef6984d5583c26abd5acef96183d81b74ac313842a7710d989 size: 2197
```

10. Deploy:

```
Client Version: v1.35.0
Kustomize Version: v5.7.1
Server Version: v1.35.0
NAME                STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION      CONTAINER-RUNTIME
s17-control-plane   Ready    control-plane   22s   v1.35.0   172.18.0.2    <none>        Debian GNU/Linux 12 (bookworm)   6.17.0-1022-azure   containerd://2.2.0
secret/ghcr-pull created
deployment.apps/session17-python created
service/session17-python created
Waiting for deployment "session17-python" rollout to finish: 0 of 2 updated replicas are available...
Waiting for deployment "session17-python" rollout to finish: 1 of 2 updated replicas are available...
deployment "session17-python" successfully rolled out
NAME                               READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS         IMAGES                                                                                    SELECTOR
deployment.apps/session17-python   2/2     2            2           5s    session17-python   ghcr.io/sammyurfen/devops-session-17-devsecops:eedd9f0f5cd1014d63843c054b962b209770ce77   app=session17-python
...
NAME                                    READY   STATUS    RESTARTS   AGE   IP           NODE                NOMINATED NODE   READINESS GATES
pod/session17-python-6547c9c945-h67xc   1/1     Running   0          5s    10.244.0.6   s17-control-plane   <none>           <none>
pod/session17-python-6547c9c945-z5d6j   1/1     Running   0          5s    10.244.0.5   s17-control-plane   <none>           <none>
NAME                       TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE   SELECTOR
service/kubernetes         ClusterIP   10.96.0.1       <none>        443/TCP        25s   <none>
service/session17-python   NodePort    10.96.245.191   <none>        80:30001/TCP   5s    app=session17-python
{"status":"healthy","timestamp":"2026-10-07T14:54:15.136736Z","uptime_seconds":1.26}
{"message":"Greetings, Bibek! You rock! 🌟","name":"Bibek","timestamp":"2026-10-07T14:54:15.144169Z"}
```

## Proof the gate works: a fake leaked key

I pushed a branch `demo-leak` with a file `leak-demo.txt` that holds a made-up AWS access key ID.
It is not a real key and was never valid.

The first try was not caught (run 37640697127, all green). The cause was my fake key, not gitleaks.
The `aws-access-token` rule only matches `AKIA` followed by 16 characters from `A-Z2-7` (base32), and my
string had an `8` in it. A real AWS key ID can never contain `8`, so the rule was right to skip it. I
changed the fake value to a base32-shaped string and pushed again. Run 37641017962:

```
$ gh run view 37641017962
X demo-leak DevSecOps pipeline · 37641017962
Triggered via push about 1 minute ago

JOBS
✓ 1. Build in 9s (ID 112859673515)
✓ 2. Unit test in 20s (ID 112859772581)
✓ 3. SAST (Bandit) in 9s (ID 112859964190)
✓ 4. SCA (pip-audit) in 23s (ID 112860064511)
X 5. Secret scan (gitleaks) in 7s (ID 112860256838)
  ✓ Set up job
  ✓ Run actions/checkout@v4
  ✓ Install gitleaks
  X Scan history
...
```

```
$ gh run view 37641017962 --log-failed
...
Finding:     aws_access_key_id = REDACTED
Secret:      REDACTED
RuleID:      aws-access-token
Entropy:     4.021928
File:        leak-demo.txt
Line:        2
Commit:      ea0424ea0d765851ebee03114f62e3f37fb9bd56
Author:      SammyUrfen
Email:       bibekcharah@gmail.com
Date:        2026-10-07T14:57:10Z
Fingerprint: ea0424ea0d765851ebee03114f62e3f37fb9bd56:leak-demo.txt:aws-access-token:2

INF 6 commits scanned.
INF scanned ~51069 bytes (51.07 KB) in 127ms
WRN leaks found: 1
##[error]Process completed with exit code 1.
```

The image, push and deploy jobs never started. Then I deleted the branch:

```
$ git push origin --delete demo-leak
$ git branch -D demo-leak
Deleted branch demo-leak (was ea0424e).
$ git ls-remote --heads origin
eedd9f0f5cd1014d63843c054b962b209770ce77	refs/heads/main
```

## Findings

| # | What happened | Cause | Fix |
|---|---|---|---|
| 1 | Run 37638726418 failed at "Install Trivy" | the `install.sh` script from Trivy's `main` branch found v0.67.2 but exited 1 | install Trivy from Aqua's official apt repository instead |
| 2 | Bandit HIGH B201 in the course app | `app.run(debug=True)` | debug only when `FLASK_DEBUG=1` |
| 3 | pip-audit: pytest 8.4.2 PYSEC-2026-1845 | old pin in the course demo | pytest 9.0.3, pytest-cov 7.0.0 |
| 4 | 44 unfixed HIGH CVEs in `python:3.12-slim` | Debian base ships many packages the app does not use | `python:3.12-alpine` |
| 5 | Run 37639688724 failed at the gate: 4 fixable HIGH | pip's vendored libs in the leftover `ensurepip` wheel | remove pip and `ensurepip` from the runtime image |
| 6 | First fake key was not detected | my fake key had a non-base32 character | use a correctly shaped fake value |
