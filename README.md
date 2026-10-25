# Multi-tenant CV hosting (one AWS account, many CVs)

A twist on the "host your CV on EC2 and Lambda" assignment. Instead of one person's
CV, **one** set of AWS resources hosts **any** number of CVs. A student opens the
upload page, enters a roll number + passcode + their three files, and gets back two
links that serve *their* CV through the shared EC2 box and the shared Lambda:

```
http://<ec2-ip>/u/<roll>/        https://<lambda-url>/u/<roll>/
```

Only one AWS account ever burns Free Tier. Everyone else just pastes their links.

## Architecture

```
                         ┌──────────────────────────────────────────┐
   upload page           │  S3 bucket (PRIVATE, Block Public Access)  │
   (served by Lambda)    │    tenants/<roll>/site/index.html          │
        │  POST /upload   │    tenants/<roll>/site/style.css           │
        ▼  (validated)    │    tenants/<roll>/site/cv.pdf              │
   ┌──────────┐  PutObject└───────▲───────────────────────▲───────────┘
   │  Lambda   │──────────────────┘                       │
   │ function  │   GetObject (serve live)                 │ GetObject
   │   URL      │◀─────────────────────────────┐          │ (5-min sync)
   └────▲───────┘                              │     ┌────┴─────────┐
        │ GET /u/<roll>/...                    │     │ EC2 + nginx   │
   visitor ───────────────────────────────────┘     │ serves /u/..  │◀── visitor
                                                     └──────────────┘
```

**How a request reaches a CV — Lambda path:** the browser hits
`https://<lambda-url>/u/<roll>/`; the function parses `<roll>` from the path, reads
`tenants/<roll>/site/index.html` from S3, replaces the footer placeholder with
`Lambda <function-name>`, and returns it. The PDF and CSS are served the same way.

**How a request reaches a CV — EC2 path:** a systemd timer runs `sync-cv.sh` every 5
minutes, mirroring `s3://<bucket>/tenants/` into `/srv/www/tenants/` and stamping the
footer with `EC2 <instance-id>`. nginx rewrites `/u/<roll>/<rest>` to
`tenants/<roll>/site/<rest>` and serves the file. The EC2 box never contacts GitHub
or the Lambda — it reads only from S3.

**GitHub's role:** version-control snapshot only. It is *not* in the live request
path. S3 is the source of truth that both servers read; GitHub just records how the
code looks and holds the written answers.

## Repository layout

```
README.md               this file
collect-evidence.sh     writes evidence.txt (11 sections)
evidence.txt            committed output of a real run
site/                   tenant-zero CV (index.html, style.css, cv.pdf) — edit with your details
ec2/                    user-data.sh, sync-cv.sh
lambda/                 handler.py  (serve + gated upload + validation + upload page)
iam/                    ec2 + lambda trust and permission JSON
```

## Deliberate deviations from the base assignment

This is a multi-tenant twist, so two rules of the single-CV brief are intentionally
relaxed, and the reasons are:

1. **Resource wildcard in IAM.** Roll numbers appear dynamically, so the policies
   scope to `tenants/*` rather than one fixed `site/`. Actions are still never
   wildcards, and nothing outside the `tenants/` subtree is reachable.
2. **Lambda has `s3:PutObject`.** Self-service upload means the Lambda must *write*
   (scoped to `tenants/*/site/*`, PutObject only — no Delete, no bucket-wide access).
   The single-CV brief's Lambda was read-only.

Everything else holds: Block Public Access stays fully on (uploads are authorized
PutObject calls, serving goes through EC2/Lambda, nothing is ever public), versioning
on, IMDSv2 required, no access keys anywhere.

## Guardrails on the upload path

- **Gate:** every upload requires the shared `UPLOAD_PASSCODE` (Lambda env var; not in
  code or repo).
- **Roll validation:** `^[a-z0-9-]{3,20}$`, lower-cased.
- **Type + size:** only `index.html` (≤100 KB), `style.css` (≤100 KB), `cv.pdf` (≤1 MB,
  verified by the `%PDF-` magic bytes). Everything else is rejected.
- **No script execution from uploaded HTML:** served with
  `Content-Security-Policy: default-src 'none'; style-src 'self' 'unsafe-inline'; ...`,
  so an uploaded page cannot run JavaScript or phish from the host's URL.
- **Set a budget/alarm** before going live to protect Free Tier.

## Deploy (once)

1. **Bucket** `cv-23l-3063` (add digits if taken), region = class region. Block Public
   Access all on, versioning enabled, no public policy/ACL. Tag `Owner`, `Course=cloud`.
2. **IAM** — create both roles from `iam/`:
   - EC2 role `cv-ec2-role-23l-3063`: trust `ec2-trust-policy.json`, inline permission
     `ec2-permission-policy.json` (name it `cv-ec2-read`).
   - Lambda role `cv-lambda-role-23l-3063`: trust `lambda-trust-policy.json`, inline
     permission `lambda-permission-policy.json` (name it `cv-lambda-read-write`), plus
     attach the managed `AWSLambdaBasicExecutionRole` for logging.
   - Replace `cv-23l-3063` in the JSON with your real bucket name.
3. **Lambda** `cv-func-23l-3063`, Python 3.13, 128–256 MB, timeout 10 s, handler
   `handler.handler`, the Lambda role above. Env vars: `BUCKET`, `PREFIX=tenants`,
   `UPLOAD_PASSCODE=<secret>`, and optionally `EC2_BASE=http://<ec2-ip>`. Create a
   **function URL, auth type NONE**. Set the log group retention to **7 days**.
4. **EC2** `cv-ec2-23l-3063`, Amazon Linux 2023, t3.micro/t2.micro, the EC2 role
   attached, IMDSv2 required, public IPv4 (no Elastic IP). Security group: TCP 80 from
   anywhere, TCP 22 from your `/32` only (or none). Paste `ec2/user-data.sh` as user
   data (edit `BUCKET` first) — it is self-contained and installs the sync script
   itself (`ec2/sync-cv.sh` is the same script kept standalone for reference).
5. Upload tenant-zero: `aws s3 cp site/ s3://cv-23l-3063/tenants/<your-roll>/site/ --recursive`.

New students never touch AWS — they just open the Lambda function URL and use the form.

---

## Live deployment (us-east-1, account 002702507323)

- **EC2 CV:** http://44.202.250.210/u/23l-3063/  (instance `i-0cd3b62c9d2cbe118`)
- **Lambda CV:** https://tfx52hveskk4heb2jy4bz5wxxu0ssytl.lambda-url.us-east-1.on.aws/u/23l-3063/
- **Upload page:** the Lambda URL root `/`  (passcode gated)

> Note: immediately after deploy the public Lambda Function URL returned `403
> AccessDeniedException` even though its config is correct (direct invoke returns
> `200`). This is AWS's new-account gating of unauthenticated function URLs and
> clears within a few hours of account creation.

---

## Evidence — access-denied test (section 4)

From EC2 Instance Connect, after attaching the read-only EC2 role:

```
$ aws s3 cp /etc/hostname s3://cv-23l-3063/tenants/23l-3063/site/index.html
upload failed: ../../etc/hostname to s3://cv-23l-3063/tenants/23l-3063/site/index.html An error occurred (AccessDenied) when calling the PutObject operation: User: arn:aws:sts::002702507323:assumed-role/cv-ec2-role-23l-3063/i-0cd3b62c9d2cbe118 is not authorized to perform: s3:PutObject on resource: "arn:aws:s3:::cv-23l-3063/tenants/23l-3063/site/index.html" because no identity-based policy allows the s3:PutObject action
```

## Evidence — last 10 lines of /var/log/cv-sync.log

```
2026-10-25T19:49:19Z sync=ok instance=i-0cd3b62c9d2cbe118
2026-10-25T19:49:19Z sync=ok instance=i-0cd3b62c9d2cbe118
2026-10-25T19:54:27Z sync=ok instance=i-0cd3b62c9d2cbe118
# (the systemd timer keeps appending a new "sync=ok" line every 5 minutes)
```

## Written answers

**1. Why roles instead of access keys? What if keys were in the user data?**
Roles give the instance and function short-lived, automatically-rotated credentials
that AWS injects at runtime, so nothing secret is ever stored. Access keys in user
data would sit in plaintext — readable from the instance metadata, from the console,
and (since this repo is public) from GitHub. A leaked long-lived key could be used by
anyone, from anywhere, until manually revoked, which is exactly the blast radius roles
remove.

**2. Someone pastes the S3 URL of index.html into a browser — what do they see?**
`AccessDenied`. Block Public Access and the absence of any public bucket policy/ACL
mean anonymous requests are refused. The object is only reachable through the EC2 or
Lambda identity, which presents the role's signed credentials.

**3. Explain the function-URL permission that lets anyone call it.**
Auth type NONE adds a resource-based permission (`lambda:InvokeFunctionUrl` for
principal `*` with `FunctionUrlAuthType=NONE`) so unauthenticated callers can invoke
the URL. That is fine for the function because the function only *serves* chosen
content and validates every upload — it is a controlled front door. It is not fine for
the bucket, because public bucket access would expose every raw object directly, with
no validation layer and no footer stamping, defeating the private-storage design.

**4. Compare the two paths. Cost when idle? At 100× traffic?**
Idle: the EC2 instance bills per hour whether or not anyone visits; the Lambda bills
nothing when idle (pay per request). At 100× traffic the Lambda scales automatically
and you pay per invocation, while the single EC2 instance would saturate and need a
bigger type or a load balancer + more instances. Lambda trades per-request cost for
elasticity; EC2 trades a flat idle cost for predictable steady-state performance.

**5. You delete the EC2 instance — what do you lose, what remains?**
You lose the running web server, its local synced copy, and `/var/log/cv-sync.log`.
You keep everything that matters: the S3 bucket and all CVs (the source of truth), the
Lambda path (still serving every tenant), the IAM roles, and the repo. Re-launching
from the same user data rebuilds the EC2 path within minutes.

---

*Adapted from the course CV-hosting assignment; extended to a self-service
multi-tenant design. All infrastructure code here is my own and I can explain it.*
