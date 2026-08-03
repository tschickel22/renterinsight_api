# Domain Connect onboarding

Domain Connect lets a tenant approve our DNS records in their registrar's own UI instead of
copying five records by hand. It is an accelerator layered on top of the manual record
table in Company Settings, never a replacement: Cloudflare does not implement Domain
Connect at all, so the manual path has to keep working for everyone.

## What is already built

- `DomainConnect::Discovery` resolves `_domainconnect.<domain>` and reads the provider's
  `/v2/<domain>/settings` endpoint.
- `DomainConnect::ApplyLink` builds and signs the synchronous apply URL.
- `GET /api/v1/company-domains/:id/domain-connect` returns `supported`, `apply_url` and a
  reason when unsupported.

All of it degrades to `supported: false` rather than raising, so shipping it cannot break
the manual flow.

## What still has to happen outside the code

This is the part with a lead time we do not control. Start it as soon as the DNS record
shape is settled, not after the rest is built.

### 1. Generate the signing keypair

The Templates repo requires `syncPubKeyDomain`, so signing is effectively mandatory.

```bash
openssl genrsa -out domain_connect_private.pem 2048
openssl rsa -in domain_connect_private.pem -pubout -out domain_connect_public.pem
```

Set `DOMAIN_CONNECT_PRIVATE_KEY` (full PEM) and `DOMAIN_CONNECT_PROVIDER_ID`
(`dealertide.com`) in Render. Until both are set, `apply_url` is nil and every tenant sees
the manual table, which is the correct fallback.

### 2. Publish the public key in DNS

Publish the base64 body of the public key (no PEM header/footer, no line breaks) as a TXT
record at:

```
_dck1.dealertide.com
```

`_dck1` matches `ApplyLink::KEY_HOST`. Rotating keys means publishing `_dck2` and changing
that constant, so old signed links stay valid during the switch.

### 3. Submit the template

`dealertide.com.email.json` in this directory is the template to submit.

1. Validate it in the [online editor](https://domainconnect.paulonet.eu/dc/free/templateedit)
   and with [dc-template-linter](https://github.com/Domain-Connect/dc-template-linter). A
   link to passing results is required in the PR.
2. Fork [Domain-Connect/Templates](https://github.com/Domain-Connect/Templates), add the
   file, open a PR using their PR template without altering its structure.

### 4. Onboard with each DNS provider separately

**Publishing to the repo does not make a provider honour the template.** Per the spec,
"this is done by contacting them," and some providers "may require contractual terms and
further template review." There is no published timeline. GoDaddy first, since it covers a
large share of SMB dealers.

Until a provider has onboarded us, discovery may report `supported: true` while the apply
URL 404s on their side. The UI presents auto-apply as an alternative to the manual records
rather than replacing them, so a tenant is never stuck.

## Prior art worth reading first

MailerSend and MailerLite both publish Domain Connect templates covering DKIM with
per-domain dynamic tokens, which is exactly our shape.
