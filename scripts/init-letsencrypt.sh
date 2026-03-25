#!/bin/bash

# Load .env from project root
if [ -f "$(dirname "$0")/../.env" ]; then
  set -o allexport
  source "$(dirname "$0")/../.env"
  set +o allexport
fi

if [ -z "$DOMAIN" ]; then
  echo "Error: DOMAIN is not set. Add it to your .env file."
  exit 1
fi

domains=("$DOMAIN")
email="${CERTBOT_EMAIL}"
data_path="./data/certbot"
staging=0  # set to 1 to test against Let's Encrypt staging (avoids rate limits)

# Generate nginx config from template
echo "Generating nginx config from template..."
envsubst '${DOMAIN}' < "$(dirname "$0")/../nginx/nginx.prod.conf.template" \
  > "$(dirname "$0")/../nginx/nginx.prod.conf"

if [ -d "$data_path" ]; then
  read -p "Existing data found. Continue and replace? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi

# Download recommended TLS parameters if not present
if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "Downloading recommended TLS parameters..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf \
    > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem \
    > "$data_path/conf/ssl-dhparams.pem"
fi

# Create dummy certificate so nginx can start
echo "Creating dummy certificate for ${domains[0]}..."
path="/etc/letsencrypt/live/${domains[0]}"
mkdir -p "$data_path/conf/live/${domains[0]}"
docker compose -f docker-compose-prod.yml run --rm --entrypoint \
  "openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot

# Start nginx with dummy cert
echo "Starting nginx..."
docker compose -f docker-compose-prod.yml up --force-recreate -d nginx

# Delete dummy certificate
echo "Deleting dummy certificate..."
docker compose -f docker-compose-prod.yml run --rm --entrypoint \
  "rm -rf /etc/letsencrypt/live/${domains[0]} \
          /etc/letsencrypt/archive/${domains[0]} \
          /etc/letsencrypt/renewal/${domains[0]}.conf" certbot

# Request real certificate
echo "Requesting Let's Encrypt certificate for ${domains[*]}..."
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

staging_arg=""
if [ "$staging" != "0" ]; then staging_arg="--staging"; fi

docker compose -f docker-compose-prod.yml run --rm --entrypoint \
  "certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $domain_args \
    --email $email \
    --rsa-key-size 4096 \
    --agree-tos \
    --force-renewal" certbot

# Reload nginx with real cert
echo "Reloading nginx..."
docker compose -f docker-compose-prod.yml exec nginx nginx -s reload

echo "Done. Run: docker compose -f docker-compose-prod.yml up -d"
