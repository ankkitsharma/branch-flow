# Nginx SSL Plan

## Current State

- `client/Dockerfile`: Multi-stage — Node builds the app, nginx:alpine serves `dist/`. Nginx logic is baked into the client image.
- `client/nginx.conf`: Nginx config co-located inside `client/`.
- `docker-compose.yml`: Single `prod` service, build context `./client`, port `80:80`. No dedicated nginx service.

## Target Architecture

```
repo-root/
├── nginx/
│   └── nginx.conf          ← nginx config lives here
├── certs/                  ← SSL certs live here (gitignored)
│   ├── self-signed.crt
│   └── self-signed.key
├── client/
│   ├── Dockerfile          ← build-only, zero nginx logic
│   └── Dockerfile.dev
├── docker-compose.yml
└── docker-compose-dev.yml
```

- `client/Dockerfile` — stripped to build + static file server only. No nginx.
- `nginx` service in `docker-compose.yml` — uses `image: nginx:alpine` directly. Nginx config and certs are volume-mounted from root.
- Nginx proxies to the `client` service internally over Docker's network. Only nginx's ports are exposed to the host.

---

## Phase 1: Self-Signed SSL (Testing)

### Step 1 — Update `client/Dockerfile`

Remove all nginx logic. The production stage serves the built files with `serve`, a lightweight static file server. Nginx will proxy to this container on port 3000 over the internal Docker network.

```dockerfile
# build stage
ARG NODE_VERSION=24.14.0-alpine

FROM node:${NODE_VERSION} AS build

WORKDIR /app

COPY package*.json ./

RUN npm ci

COPY . .

RUN npm run build

# production stage
FROM node:${NODE_VERSION}

WORKDIR /app

RUN npm install -g serve

COPY --from=build /app/dist ./dist

EXPOSE 3000

CMD ["serve", "-s", "dist", "-l", "3000"]
```

> `client/nginx.conf` can now be deleted — nginx config moves to root.

---

### Step 2 — Create `nginx/nginx.conf`

Create the `nginx/` directory at the repo root and add `nginx.conf` inside it:

```nginx
server {
    listen 80;
    server_name localhost;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name localhost;

    ssl_certificate     /etc/nginx/ssl/self-signed.crt;
    ssl_certificate_key /etc/nginx/ssl/self-signed.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers   HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://client:3000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

`http://client:3000` is the internal Docker network address of the `client` service defined in docker-compose.

---

### Step 3 — Generate the Self-Signed Certificate

Run this once on your machine. It creates the `certs/` directory at the repo root and generates the cert:

```bash
mkdir -p certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout certs/self-signed.key \
  -out certs/self-signed.crt \
  -subj "/C=US/ST=Local/L=Local/O=Dev/CN=localhost"
```

Add `certs/` to `.gitignore` so keys are never committed:

```
# .gitignore
certs/
```

---

### Step 4 — Update `docker-compose.yml`

```yaml
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./certs:/etc/nginx/ssl:ro
    depends_on:
      - client

  client:
    build:
      context: ./client
      dockerfile: Dockerfile
    container_name: client
    environment:
      - NODE_ENV=production
```

Note: the `client` service has no `ports` — it is intentionally not exposed to the host. All traffic goes through nginx.

---

### Step 5 — Test It

```bash
docker compose up --build
```

Open `https://localhost`. Accept the browser warning for the self-signed cert.

To suppress the warning on macOS by trusting the cert locally:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ./certs/self-signed.crt
```

---

## Phase 2: Real SSL with Certbot (Production)

### What changes from Phase 1

| File | Change |
|------|--------|
| `client/Dockerfile` | No change |
| `nginx/nginx.conf` | `server_name` → real domain; cert paths → Let's Encrypt |
| `docker-compose.yml` | Swap `./certs` volume for `/etc/letsencrypt` host mount |
| Host | Run `certbot` once to obtain certs |

---

### Step 1 — Update `nginx/nginx.conf`

```nginx
server {
    listen 80;
    server_name app.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name app.example.com;

    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers   HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://client:3000;
        proxy_set_header   Host $host;
        proxy_set_header   X-Real-IP $remote_addr;
        proxy_set_header   X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
    }
}
```

---

### Step 2 — Obtain the Certificate (once, on the host)

Port 80 must be free — stop containers first:

```bash
docker compose down

# Debian/Ubuntu
sudo apt install certbot
# Fedora/RHEL
sudo dnf install certbot

sudo certbot certonly --standalone -d app.example.com
```

Certbot writes certs to `/etc/letsencrypt/live/app.example.com/` on the host.

---

### Step 3 — Update `docker-compose.yml`

Swap the `./certs` volume for the host's `/etc/letsencrypt`:

```yaml
services:
  nginx:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /etc/letsencrypt:/etc/letsencrypt:ro
    depends_on:
      - client

  client:
    build:
      context: ./client
      dockerfile: Dockerfile
    container_name: client
    environment:
      - NODE_ENV=production
```

---

### Step 4 — Automate Certificate Renewal

Let's Encrypt certs expire every 90 days. Add a cron job on the host:

```bash
crontab -e

# Runs at 3am on the 1st of each month
0 3 1 * * certbot renew --quiet && docker compose -f /path/to/docker-compose.yml exec nginx nginx -s reload
```

---

## Summary of Differences

| Concern               | Self-Signed (Testing)                          | Certbot (Production)                              |
|-----------------------|------------------------------------------------|---------------------------------------------------|
| `client/Dockerfile`   | No change between phases                       | No change between phases                          |
| `nginx/nginx.conf`    | `server_name localhost`, `/etc/nginx/ssl/`     | `server_name app.example.com`, letsencrypt paths  |
| Cert source           | `./certs/` generated locally via openssl       | `/etc/letsencrypt` mounted from host              |
| `docker-compose.yml`  | Mount `./certs:/etc/nginx/ssl`                 | Mount `/etc/letsencrypt:/etc/letsencrypt`         |
| Renewal               | Regenerate certs + restart                     | Certbot cron + `nginx -s reload`                  |
| Browser trust         | Warning (optionally trust via OS keychain)     | Trusted automatically by all browsers             |