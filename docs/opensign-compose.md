# OpenSign Compose Option

OpenSign can run beside D6E on the same VPS by adding
`opensign/compose.yml` to the deployment's Compose command. This option only
co-locates the services. It does not add OpenSign APIs, contract data, or
signing actions to D6E.

## Topology

- D6E remains on `D6E_DOMAIN`.
- OpenSign is served from the separate `OPENSIGN_DOMAIN` hostname.
- Caddy is the only OpenSign service publishing host ports 80 and 443.
- OpenSign client, server, and MongoDB ports are not published on the host.
- MongoDB uses an internal-only network and separate named volume.
- Uploaded and signed files use a separate named volume.

Budget enough CPU, memory, and disk I/O for D6E, OpenSign, and MongoDB to run
together. MongoDB 8 requires a compatible VPS CPU. The base D6E Compose file
also publishes ports 3000, 8080, and 8081. Restrict those ports to trusted
sources with the VPS or provider firewall; only ports 80 and 443 should be
publicly reachable for web traffic.

## Configure

Create the deployment environment files:

```bash
cp .env.example .env
cp opensign/.env.example opensign/.env
```

Configure D6E in `.env`, then replace every empty required value in
`opensign/.env`. Use URL-safe hexadecimal values for the MongoDB password and
an independent OpenSign master key:

```bash
openssl rand -hex 24
openssl rand -hex 24
```

Set `D6E_DOMAIN` to the existing D6E hostname and `OPENSIGN_DOMAIN` to the
separate OpenSign hostname. Create their DNS records before starting the stack
so Caddy can issue HTTPS certificates.

OpenSign also requires a PKCS#12 signing certificate. For initial evaluation,
create a self-signed certificate:

```bash
install -d -m 700 opensign/secrets
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
  -subj "/CN=d6e OpenSign" \
  -keyout opensign/secrets/signing.key \
  -out opensign/secrets/signing.crt
openssl pkcs12 -export \
  -inkey opensign/secrets/signing.key \
  -in opensign/secrets/signing.crt \
  -out opensign/secrets/signing.p12
base64 -w 0 opensign/secrets/signing.p12
```

Store the Base64 output and export passphrase in `opensign/.env`, then remove
the temporary certificate files after transferring them to the deployment's
secret-management system. PDF readers do not automatically trust the identity
of a self-signed certificate. Use an organization-controlled signing
certificate before production use.

## Validate and start

Validate the merged Compose model before starting it:

```bash
docker compose --env-file .env --env-file opensign/.env \
  -f compose.yml -f opensign/compose.yml config --quiet
docker compose --env-file .env --env-file opensign/.env \
  -f compose.yml -f opensign/compose.yml up -d
```

When a deployment has a local `compose.override.yml`, an explicit `-f` command
does not automatically load it. Include the override between the base file and
the OpenSign overlay so instance-specific image and environment settings remain
active:

```bash
docker compose --env-file .env --env-file opensign/.env \
  -f compose.yml -f compose.override.yml -f opensign/compose.yml config --quiet
docker compose --env-file .env --env-file opensign/.env \
  -f compose.yml -f compose.override.yml -f opensign/compose.yml up -d
```

Check both public endpoints and the container health after startup. Test account
creation, password reset, invitation email, upload, signing, and signed-document
download before offering the service to a customer.

## Backup

Back up both `opensign_mongo_data` and `opensign_files`. A database dump alone
does not include uploaded or signed files. Create a MongoDB archive with:

```bash
install -d -m 700 opensign/backups
docker compose --env-file .env --env-file opensign/.env \
  -f compose.yml -f opensign/compose.yml exec -T opensign-mongo \
  sh -c 'mongodump --archive --gzip \
  --username "$MONGO_INITDB_ROOT_USERNAME" \
  --password "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin' > opensign/backups/opensign-mongo.archive.gz
```

Use a volume-aware backup tool or a VPS snapshot for `opensign_files`, and test
restoring the database and files together. Do not run `docker compose down -v`
unless permanent deletion of both OpenSign volumes is intended.

## Update or disable

The example pins each OpenSign and MongoDB image to a digest. To update, replace
the digest deliberately, review upstream release changes, pull, recreate, and
run the signing smoke test again.

To disable OpenSign without deleting its named volumes, remove the OpenSign
containers and recreate Caddy with the normal deployment configuration:

```bash
docker compose --env-file .env --env-file opensign/.env \
  -f compose.yml -f opensign/compose.yml rm -sf \
  opensign-client opensign-server opensign-mongo
docker compose --env-file .env -f compose.yml up -d --force-recreate caddy
```

Include any instance-specific `compose.override.yml` in both commands when the
deployment uses one.

## Security and product boundary

- Keep `opensign/.env`, SMTP credentials, certificate material, and backups out
  of Git.
- Restrict VPS and backup access; contracts and signatures are sensitive data.
- Co-location is not a hard security boundary. The D6E API mounts the Docker
  socket for its Docker STF runtime, so compromise of that container can expose
  OpenSign containers, environment variables, and volumes. Use a separate VPS
  or Docker daemon when hard isolation is required.
- Configure retention, privacy notices, and signing policy for the deployment's
  jurisdiction before production use.
- OpenSign is independently licensed. Review its upstream license and notices
  before commercial distribution or modification.
- D6E integration, workspace mapping, AI contract review, OpenSign API keys,
  webhooks, and audit synchronization are intentionally out of scope here.

## Upstream references

- <https://github.com/OpenSignLabs/OpenSign>
- <https://docs.opensignlabs.com/docs/self-host/docker/run-locally>
