# Security policy

## Scope

snapcompose is a distribution of plugins on top of rlock targeted at CI
workloads. Security boundary considerations specific to this
distribution:

- `snapc pr <pr-ref>` runs untrusted PR code in the VM. The framework's
  VM isolation (rlock) is the boundary; snapcompose's `snapc-pr`
  shouldn't widen it by reaching into host state from the PR's
  context.
- `docker-registry-cache` runs a host-side OCI registry proxy on
  `127.0.0.1:5000`. Should not be exposed beyond loopback.
- `[on_start.<name>]` cmds in `snapcompose.toml` run on every `snapc run`
  with host-side credentials available; the file is project-trusted
  by definition, but should never echo secrets to the guest.

## Out of scope

- Code that runs **inside** the guest VM exfiltrating data through
  channels the user explicitly configured (e.g. network in the VM
  reaching the internet for `npm install`).
- Issues in upstream rlock / aq / QEMU / Alpine / Docker.
- AI-agent specific issues — report to `ai.rlock` if that's where
  you encountered them.

## Reporting

Open a private security advisory at
[https://github.com/pirj/snapcompose/security/advisories/new](https://github.com/pirj/snapcompose/security/advisories/new).

If GitHub advisories aren't suitable, email pirjsuka@gmail.com with
"snapcompose security" in the subject.

Don't open a public issue for a credible vulnerability before the
maintainer has acknowledged it.

## Supported versions

Only the `main` branch and the most recent tagged release receive
security fixes. Pin to a tag in production and watch the changelog.
