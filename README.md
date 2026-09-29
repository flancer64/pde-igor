# pde-igor

Personal Digital Embassy for Igor Gusev.

The application composes PDE Runtime with Telegram Desk and Echo Desk. Echo Desk
is included as a deterministic local integration check; Telegram Desk requires
the Telegram API credentials configured in `.env`.

## Local setup

```sh
cp .env.example .env
npm install
npm run db:migrate
npm start
```

Before starting the application, set `PDE_RUNTIME__PERSON_SECRET` and PostgreSQL
connection values in `.env`. For Telegram Desk, additionally set
`PDE_DESK_TELEGRAM__API_ID` and `PDE_DESK_TELEGRAM__API_HASH`.
Existing deployments can continue using `PDE_RUNTIME__OWNER_SECRET` as the
Runtime's deprecated fallback until their credentials are deliberately rotated.

`npm run db:migrate` initializes a clean database or migrates a recognized
Runtime predecessor before application start. Back up an existing database
before running it. The migration recognizes the production `trusted_*` schema,
rebuilds the current `delegate_*` schema, verifies row counts, and records the
applied schema in TeqFW history.

## Verification

After dependencies are installed, run:

```sh
npm run db:migrate
./node_modules/.bin/teq web:start
```

The Echo Desk must be available without Telegram credentials; Telegram Desk is
available after its credentials and TDLib state directory are configured.

## Production environment

Before the first release, run the root provisioning script on the Debian or
Ubuntu host:

```sh
sudo BASE_URL=https://pde.example.org PORT=3000 ./scripts/create-user.sh
```

It creates the `pde-igor` service account, isolated PostgreSQL role and
database, protected state directories, private runtime configuration, NVM,
systemd unit, deployment sudoers rule, and log rotation. It installs missing
host packages, including PostgreSQL, sudo, Apache, and Certbot. It does not
deploy a release or configure Telegram credentials; add the latter to
`/home/pde-igor/private/pde/app.env` after provisioning.

The script installs Apache and Certbot, creates an HTTP virtual host, and runs
Certbot with its Apache plugin to issue a certificate and enable the HTTP to
HTTPS redirect. Certbot creates a separate `*-le-ssl.conf` virtual host; the
script adds the application proxy include to that generated SSL configuration.
The proxy forwards HTTPS traffic over h2c to `127.0.0.1:PORT`.

Set `BASE_URL` to the public HTTPS origin without a port or path. Its DNS name
must resolve to the host, and inbound ports 80 and 443 must be reachable for
certificate issuance and HTTPS traffic. `CERTBOT_EMAIL` is optional; when
omitted, Certbot registers without an email address. `PORT` sets both the local
Runtime HTTP port and Apache's h2c upstream port. Rerunning provisioning
keeps existing secrets and application data. It creates missing host resources
and rejects conflicting files or database credentials. Once provisioning ends,
run the GitHub Actions deployment workflow; it activates the release, runs
migrations, starts the service, checks its health, and handles rollback.
