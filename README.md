# Branch Flow

A modern full-stack web application built with React 19 and TanStack Router, with multi-environment Docker support and automated SSL via Let's Encrypt.

## Tech Stack

- **Frontend**: React 19, TanStack Router, Tailwind CSS v4, Vite
- **Reverse Proxy**: Nginx (with SSL termination)
- **SSL**: Self-signed certs (local) / Let's Encrypt (production)

---

## Running Without Docker

### Prerequisites

- Node.js 20+
- npm

### Setup

```bash
cd client
npm install
npm run dev
```

The client dev server runs at `http://localhost:3000`.

### Other client scripts

| Command | Description |
|---|---|
| `npm run build` | Production build |
| `npm run preview` | Preview production build |
| `npm run test` | Run tests |
| `npm run lint` | Lint code |
| `npm run check` | Format + lint (auto-fix) |

---

## Running With Docker

### Prerequisites

- Docker + Docker Compose

---

### 1. Local Dev (hot reload)

Uses `docker-compose-dev.yml`. Runs the Vite dev server with file sync for hot module reloading — no nginx, no SSL.

```bash
docker compose -f docker-compose-dev.yml watch
```

App available at `http://localhost:3000`.

File changes in `./client/src` sync into the container automatically. Changes to `package.json` or `vite.config.ts` trigger a container rebuild.

---

### 2. Prod-Local (self-signed SSL)

Uses `docker-compose.yml`. Builds the production client bundle, serves it behind nginx with self-signed SSL certificates from `./certs/`.

```bash
docker compose up --build
```

- HTTP → `http://localhost` (redirects to HTTPS)
- HTTPS → `https://localhost` (self-signed cert, browser will warn)

---

### 3. Prod-Certbot (Let's Encrypt SSL)

Uses `docker-compose-prod.yml` with certbot for automatic SSL certificate issuance and renewal. **Requires a public domain pointed at your server.**

#### Step 1: Configure environment

```bash
cp .env.example .env
```

Edit `.env`:

```env
DOMAIN=yourdomain.com
CERTBOT_EMAIL=you@yourdomain.com
```

#### Step 2: Run the init script

This generates the nginx config from the template, obtains a real Let's Encrypt certificate, and starts all services.

```bash
chmod +x scripts/init-letsencrypt.sh
./scripts/init-letsencrypt.sh
```

> Set `staging=1` inside the script to test against Let's Encrypt's staging environment and avoid rate limits during setup.

#### Step 3: Start services

```bash
docker compose -f docker-compose-prod.yml up -d
```

- HTTP → `http://yourdomain.com` (redirects to HTTPS, serves ACME challenges)
- HTTPS → `https://yourdomain.com` (valid Let's Encrypt cert)

Nginx reloads certificates every 6 hours. Certbot renews certificates every 12 hours automatically.
