# ubuntu-server-admin

Scripts for setting up and managing Ubuntu servers over SSH (PuTTY, Terminal, etc), all from this one repo:

- **App server**: nginx, PHP and a menu-driven web account manager.
- **DB server**: MySQL, PostgreSQL and/or MariaDB, locked down to the app server.

## Setting up a new server

Connect to the new server in a terminal window and run:

```bash
sudo apt install -y git
sudo git clone https://github.com/igunter/ubuntu-server-admin.git /ubuntu-server-admin
cd /ubuntu-server-admin
sudo bash setup.sh
```

`setup.sh` asks what the server is for:

```
=========== Server Setup ===========
  1  App server   (nginx, PHP, Composer, web account manager)
  2  DB server    (MySQL, PostgreSQL and/or MariaDB)
  x  Exit
```

| Choice | What it does |
| --- | --- |
| App server | Runs `install.sh` (nginx, certbot, the shared folders and the "Site Unavailable" page), then offers the PHP stack (`appserver/install-php.sh`) and the "Hello" holding page (`appserver/install-holding.sh`), and finally starts the web account manager. |
| DB server | Runs `dbserver/install-db.sh`. You tick which engines to install (MySQL, PostgreSQL, MariaDB; MySQL and MariaDB can't share a server) and give the app server's private IP, and it creates a database and a user that can only connect from that IP. The generated passwords are shown once. |

Every script is safe to run again, and any of them can be run on its own, for example `sudo bash install.sh`.

A step-by-step guide to a two-server Laravel setup on Lightsail is in [`appserver/README.md`](appserver/README.md).

## Web Account Manager

Menu-driven management of nginx web accounts on the App server.

```
=========== Web Account Manager ===========
  1  List Accounts
  2  Create Account
  3  Edit Account        (change settings / delete account)
  4  Toggle Account Status
  5  Toggle SSL
  6  Add a Domain
  7  Remove a Domain
  x  Exit
```

Start it with:

```bash
cd /ubuntu-server-admin && sudo bash webadmin.sh
```

### Updating the scripts

```bash
cd /ubuntu-server-admin && sudo git pull && sudo bash webadmin.sh
```

A server cloned under the old repo name (`/ubuntu-app-server-admin`) keeps working, because GitHub redirects the old name. To switch it to the new one:

```bash
cd /ubuntu-app-server-admin && sudo git remote set-url origin https://github.com/igunter/ubuntu-server-admin.git
```

## What the options do

| Option | Description |
| --- | --- |
| List Accounts | Shows every account with its status, SSL, PHP and domains. |
| Create Account | Creates `/var/www/<name>/public` with a "Coming Soon" placeholder `index.html`, and the nginx conf. |
| Edit Account | Change PHP on/off and max upload size, or delete the account (asks you to type the account name, and separately whether to delete the web files). |
| Toggle Account Status | When **off**, the site returns HTTP 503 and shows a "Site Unavailable" page on both HTTP and HTTPS. |
| Toggle SSL | Requests a Let's Encrypt certificate for all the account's domains and enables HTTPS with an HTTP redirect. Turning it off keeps the certificate. |
| Add a Domain | Adds a domain to an account (the certificate is expanded if SSL is on). |
| Remove a Domain | Removes a domain (the certificate is reissued if SSL is on). The last domain cannot be removed. |

## How it works

| What | Where |
| --- | --- |
| Account settings (source of truth) | `/etc/webaccounts/<name>.env` |
| Generated nginx conf | `/etc/nginx/sites-available/<name>.conf`, symlinked into `sites-enabled/` |
| Web root | `/var/www/<name>/public` |
| Disabled-site page | `/var/www/_disabled/index.html` |
| Let's Encrypt challenges | `/var/www/_acme/` |

- Confs are regenerated from the settings file on every change, so **manual edits to the generated conf will be overwritten** - use the menu instead.
- Every change is checked with `nginx -t` before nginx is reloaded. If nginx rejects it, the previous conf is restored.
- For SSL, DNS for every domain on the account must already point at the server.
- For PHP accounts, install PHP-FPM first: `sudo apt install php-fpm`.
- The document root is the account's `public` folder, so a Laravel project can live in `/var/www/<name>` and use its own `public/` folder as is. nginx does not read `.htaccess` files.
- PHP accounts send unknown paths to `index.php` (the front controller Laravel needs); accounts without PHP return 404.
- Accounts created by older versions served `public_html`. It is renamed to `public` the next time that account's conf is rewritten (any change made from the menu), and an existing `public` folder is never overwritten.

## Requirements

- Ubuntu server with root/sudo access
- Ports 80 and 443 open

## PHP / Laravel and database servers

A full step-by-step guide to a two-server Laravel setup on Lightsail (App server + DB server, nginx, HTTPS, scheduler, queues, backups, deploys) is in [`appserver/README.md`](appserver/README.md). The PHP stack and holding page scripts are in [`appserver/`](appserver/) and the database installer is in [`dbserver/`](dbserver/).

### PostgreSQL point-in-time backups

On the DB server, after `setup.sh`: `sudo bash dbserver/install-backup.sh` sets up pgBackRest with WAL archiving to an encrypted S3 bucket in London, weekly full and daily differential backups, an hourly monitor, and an every-minute archive-freshness watch (alerts within about 4 minutes if WAL stops reaching the bucket). Set that watch's own alert URL with `sudo bash dbserver/install-backup.sh archive-url`, and prove it with `sudo bash dbserver/archive-stall-test.sh` (breaks archiving on purpose for a few minutes, times the alert, then restores it). How to restore and the test checklist are in [`dbserver/RESTORE.md`](dbserver/RESTORE.md), and the first test's results are in [`dbserver/restore-test-record.md`](dbserver/restore-test-record.md).

### PostgreSQL TLS

`sudo bash dbserver/enable-tls.sh` creates a private CA and server certificate and turns TLS on. `... enforce` then rejects unencrypted remote connections (do this only after the application uses the CA certificate with `verify-full`), `... check` shows the state, and `... summary` prints the non-secret details to give the application.

### Synthetic rehearsal (review material; nothing here runs without approval)

- `dbserver/create-rehearsal-db.sh`: `plan` (default, changes nothing), `apply` and `cleanup` for an isolated empty database, its two roles and two TLS-only access lines on the database server. Refuses non-rehearsal names, the production database and application server.
- `dbserver/verify-roles.sh`: read-only check of effective privileges (26 checks, including attempted DDL as each role inside rolled-back transactions).
- `rehearsal/egress-plan.md`: host firewall plan for the temporary application host (outbound deny-by-default, IPv4 and IPv6).
- `rehearsal/scratch-storage.md`: scratch backup bucket and the two limited IAM policies for the synthetic point-in-time test.
