#!/usr/bin/env bash
# torii-suite/lib/continuum-host.sh — helpers for installers/install-continuum-host.sh.
# Sourced; pure functions so test/install-continuum-host.test.sh runs them as a user.
#
# Continuum on its own origin (continuum.<domain>) keeps its owner token out of
# the localStorage that Quest and the other apex apps share. The vhost reuses
# the fragment install-continuum.sh writes, so there is one copy of the
# /continuum/ and /agent/ locations; /api/ stays on the apex as well.

CONTINUUM_HOST_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
continuum_valid_host() { [[ "${1:-}" =~ $CONTINUUM_HOST_RE ]]; }

# continuum_host_headers <teams host|""> → nginx add_header lines. Included in
# every Continuum location (an add_header in a location drops the server's).
# The Team view frames the Teams app (Continuum v0.2.195-alpha: iframe
# allow="clipboard-write" only), so no origin gets the microphone; nothing may
# frame Continuum itself. A Teams host is still validated when given.
continuum_host_headers() {
  local teams="${1:-}" mic='()'
  if [[ -n "$teams" ]]; then
    continuum_valid_host "$teams" || return 1
  fi
  cat <<NGINX
# written by torii-suite (lib/continuum-host.sh)
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Content-Security-Policy "frame-ancestors 'none'" always;
add_header X-Frame-Options "DENY" always;
add_header Permissions-Policy 'geolocation=(), camera=(), payment=(), microphone=${mic}' always;
NGINX
}

# continuum_host_vhost <host> <cert dir> <fragment> <api snippet> <headers inc>
continuum_host_vhost() {
  local host="$1" cert="$2" frag="$3" api="$4" hdr="$5"
  continuum_valid_host "$host" || return 1
  cat <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${host};
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${host};
    ssl_certificate     ${cert}/fullchain.pem;
    ssl_certificate_key ${cert}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    server_tokens off;
    client_max_body_size 1m;
    include ${hdr};

    location = / { include ${hdr}; return 302 /continuum/; }
    location / { include ${hdr}; return 404; }
    # /continuum/ and /agent/ (install-continuum.sh) and /api/ (torii-base).
    include ${frag};
    include ${api};
}
NGINX
}

# continuum_host_redirect <host> → main-host fragment (server context): the
# apex /continuum/ moves to the Continuum host, query string kept.
continuum_host_redirect() {
  local host="$1"
  continuum_valid_host "$host" || return 1
  cat <<NGINX
# /opt/torii/nginx-fragments/continuum-host.conf - written by torii-suite install-continuum-host.sh
# Continuum runs on https://${host}; /api/ and /agent/ stay on this host too.
rewrite ^/continuum(/.*)?\$ https://${host}/continuum\$1 permanent;
NGINX
}
