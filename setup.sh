#!/usr/bin/env bash
# Krasnaya VPN / RemnaNode node-only installer v8.0.
# Node installer only; the shared Remnawave Config Profile is managed separately in the panel.
# Supported: Debian/Ubuntu, nginx, Docker Compose v2, Xray-core managed by Remnawave.
# No panel API URL/token is used.
set -Eeuo pipefail
umask 077

DOMAIN=${DOMAIN:-}
EMAIL=${EMAIL:-}
SECRET_KEY=${SECRET_KEY:-}
PANEL_IP=${PANEL_IP:-}
NODE_PORT=${NODE_PORT:-}
REALITY_PORT=${REALITY_PORT:-9443}
REALITY_WARP_PORT=${REALITY_WARP_PORT:-8443}
XHTTP_PORT=${XHTTP_PORT:-10085}
XHTTP_WARP_PORT=${XHTTP_WARP_PORT:-10086}
XHTTP_PATH=${XHTTP_PATH:-}
XHTTP_WARP_PATH=${XHTTP_WARP_PATH:-}
XHTTP_PREFIX=/relay/
XHTTP_WARP_PREFIX=/cache/
ROTATE_XHTTP_PATHS=${ROTATE_XHTTP_PATHS:-0}
PULL_NODE_IMAGE=${PULL_NODE_IMAGE:-0}
REGENERATE_SITE=${REGENERATE_SITE:-0}
ENABLE_BBR=${ENABLE_BBR:-1}
SSH_PORT=${SSH_PORT:-}
STRICT_SNI=${STRICT_SNI:-1}        # 1 = Nginx rejects TLS handshakes for unknown SNI (direct-IP probing)
CF_REFRESH=${CF_REFRESH:-1}        # 1 = weekly systemd timer refreshes the Cloudflare CIDR allowlist
NODE_IMAGE=${NODE_IMAGE:-remnawave/node:latest}
CF_HELPER=/usr/local/sbin/krasnaya-cf-refresh
UNIT_DIR=/etc/systemd/system

CONF=/etc/nginx/conf.d/stub.conf
SNIPPET_DIR=/etc/nginx/snippets
CFACL=$SNIPPET_DIR/cloudflare-allow.conf
CDN_SNIP=$SNIPPET_DIR/xhttp-location.conf
WARP_SNIP=$SNIPPET_DIR/xhttp-warp-location.conf
SITE_DIR=/var/www/stub
ACME_ROOT=/var/www/certbot
NODE_DIR=/opt/remnanode
STATE_DIR=/etc/krasnaya-node
env_value() { sed -n "s/^$1=//p" "$NODE_DIR/.env" | head -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"; }
if [[ -z "$NODE_PORT" && -f "$NODE_DIR/.env" ]]; then NODE_PORT=$(env_value NODE_PORT); fi
NODE_PORT=${NODE_PORT:-2222}
STAMP=$(date -u +%Y%m%dT%H%M%S%NZ)
BACKUP_DIR=/var/backups/krasnaya-node/$STAMP
ROLLBACK=0
BACKED_UP=()

log() { printf '\n\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ask() {
  local v="$1" label="$2" def="${3:-}" value=''
  [[ -n "${!v:-}" ]] && return 0
  if [[ -r /dev/tty ]]; then
    read -r -p "$label${def:+ [$def]}: " value </dev/tty || true
  fi
  printf -v "$v" '%s' "${value:-$def}"
}
backup() {
  local f="$1"
  mkdir -p "$BACKUP_DIR$(dirname "$f")"
  if [[ -e "$f" || -L "$f" ]]; then
    cp -a "$f" "$BACKUP_DIR$f"
  else
    touch "$BACKUP_DIR$(dirname "$f")/.absent.$(basename "$f")"
  fi
  BACKED_UP+=("$f")
}
UFW_WAS_ACTIVE=0
UFW_CHANGED=0
DOCKER_CHANGED=0
restore_all() {
  local rc=$?
  [[ "$ROLLBACK" == 1 && "$rc" -ne 0 ]] || return 0
  warn 'Installation failed; restoring backed-up files.'
  local f
  for f in "${BACKED_UP[@]}"; do
    if [[ -e "$BACKUP_DIR$f" || -L "$BACKUP_DIR$f" ]]; then
      mkdir -p "$(dirname "$f")"
      cp -a "$BACKUP_DIR$f" "$f"
    elif [[ -f "$BACKUP_DIR$(dirname "$f")/.absent.$(basename "$f")" ]]; then
      rm -f "$f"
    fi
  done
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  if [[ "$UFW_CHANGED" == 1 ]] && command -v ufw >/dev/null 2>&1; then
    if [[ "$UFW_WAS_ACTIVE" == 1 ]]; then
      ufw reload >/dev/null 2>&1 || true
    else
      ufw --force disable >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$DOCKER_CHANGED" == 1 ]] && command -v docker >/dev/null 2>&1; then
    if [[ -f "$BACKUP_DIR$NODE_DIR/docker-compose.yml" ]]; then
      (cd "$NODE_DIR" && docker compose up -d) >/dev/null 2>&1 || true
    else
      docker rm -f remnanode >/dev/null 2>&1 || true
    fi
  fi
  warn "Backup: $BACKUP_DIR"
  return "$rc"
}
trap restore_all EXIT

[[ $EUID -eq 0 ]] || die 'Run as root: sudo bash setup-node.sh'
command -v apt-get >/dev/null || die 'Debian / Ubuntu (apt) only'
manifest_value() {
  local key="$1"
  [[ -f "$STATE_DIR/manifest.env" ]] || return 0
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$STATE_DIR/manifest.env"
}
DOMAIN=${DOMAIN:-$(manifest_value DOMAIN)}
PANEL_IP=${PANEL_IP:-$(manifest_value PANEL_IP)}
ask DOMAIN 'Public HTTPS domain of this node (Cloudflare proxied)' ''
ask PANEL_IP 'Remnawave panel source IP reaching this node' ''
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && [[ "$DOMAIN" == *.* ]] && [[ "$DOMAIN" != *..* ]] || die 'Invalid DOMAIN'
[[ -n "$PANEL_IP" ]] || die 'PANEL_IP is required to restrict the RemnaNode management port.'
[[ "$EMAIL" != *[[:space:]]* ]] || die 'EMAIL may not contain spaces'
for v in NODE_PORT REALITY_PORT REALITY_WARP_PORT XHTTP_PORT XHTTP_WARP_PORT; do
  n=${!v}
  [[ "$n" =~ ^[0-9]+$ ]] && (( n>=1024 && n<=65535 )) || die "Invalid port: $v=$n"
done
[[ "$XHTTP_PORT" != "$XHTTP_WARP_PORT" ]] || die 'XHTTP internal ports must differ'
[[ "$REALITY_PORT" != 443 && "$REALITY_WARP_PORT" != 443 ]] || die 'Port 443 belongs to Nginx'
[[ "$REALITY_PORT" != "$REALITY_WARP_PORT" ]] || die 'REALITY ports must differ'
for v in STRICT_SNI CF_REFRESH ENABLE_BBR PULL_NODE_IMAGE REGENERATE_SITE; do
  [[ "${!v}" == 0 || "${!v}" == 1 ]] || die "$v must be 0 or 1"
done
[[ "$NODE_IMAGE" =~ ^[a-z0-9][a-z0-9./_-]*(:[A-Za-z0-9._-]+)?$ ]] || die 'Invalid NODE_IMAGE'

log 'Installing dependencies'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates nginx certbot openssl python3 iproute2 ufw >/dev/null
if ! command -v docker >/dev/null 2>&1; then
  warn 'Docker is missing; installing using the official Docker convenience installer.'
  INSTALL_SH=$(mktemp)
  curl -fsS --retry 2 https://get.docker.com -o "$INSTALL_SH" || die 'Cannot download Docker installer'
  sh "$INSTALL_SH" || die 'Docker installation failed'
  rm -f "$INSTALL_SH"
fi
systemctl enable --now docker >/dev/null
if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin >/dev/null 2>&1 || die 'Docker Compose plugin missing; install docker-compose-plugin'
fi

# The existing raw/REALITY :443 must be migrated in the panel BEFORE Nginx can listen on :443.
if ss -Hltpn '( sport = :443 )' 2>/dev/null | grep -q .; then
  if ss -Hltpn '( sport = :443 )' 2>/dev/null | grep -v -q 'nginx'; then
    die 'Port 443 is used by something other than Nginx. Apply profile (REALITY to 9443) in Remnawave first.'
  fi
fi

if ss -Hltpn '( sport = :80 )' 2>/dev/null | grep -v -q 'nginx'; then
  die 'Port 80 is used by something other than Nginx (needed for ACME and the HTTPS redirect).'
fi

log 'Checking domain and Cloudflare ranges'
getent ahostsv4 "$DOMAIN" >/dev/null || warn "Domain does not resolve from this node yet: $DOMAIN"
# The same helper is installed on the node and run weekly by a systemd timer.
CF_HELPER_SRC=$(mktemp)
cat > "$CF_HELPER_SRC" <<'CFHELPER'
#!/usr/bin/env bash
# Krasnaya node: refresh the Cloudflare CIDR allowlist used by the Nginx XHTTP locations.
set -Eeuo pipefail
CFACL=${CFACL:-/etc/nginx/snippets/cloudflare-allow.conf}
fetch() { curl -fsS --retry 3 --retry-delay 2 --max-time 20 "$1"; }
V4=$(fetch https://www.cloudflare.com/ips-v4) || { echo 'Cannot fetch Cloudflare IPv4 CIDRs' >&2; exit 1; }
V6=$(fetch https://www.cloudflare.com/ips-v6) || { echo 'Cannot fetch Cloudflare IPv6 CIDRs' >&2; exit 1; }
LIST=$(printf '%s\n%s\n' "$V4" "$V6" | python3 -c '
import ipaddress,sys
lines=[l.strip() for l in sys.stdin if l.strip()]
nets=[ipaddress.ip_network(l,strict=True) for l in lines]
if sum(n.version==4 for n in nets)<5 or sum(n.version==6 for n in nets)<3:
    raise SystemExit("Unexpectedly short Cloudflare list")
for n in nets: print("allow %s;"%n)
print("deny all;")
') || { echo 'Invalid Cloudflare CIDR list' >&2; exit 1; }
if [[ "${1:-}" == --stdout ]]; then printf '%s\n' "$LIST"; exit 0; fi
TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP.bak"' EXIT
printf '%s\n' "$LIST" > "$TMP"
if [[ -f "$CFACL" ]] && cmp -s "$TMP" "$CFACL"; then exit 0; fi
[[ ! -f "$CFACL" ]] || cp -a "$CFACL" "$TMP.bak"
install -m 644 "$TMP" "$CFACL"
if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx
  logger -t krasnaya-cf-refresh 'Cloudflare allowlist updated'
else
  [[ ! -f "$TMP.bak" ]] || cp -a "$TMP.bak" "$CFACL"
  echo 'nginx -t failed; previous allowlist restored' >&2
  exit 1
fi
CFHELPER
CF_ALLOW_TXT=$(bash "$CF_HELPER_SRC" --stdout) || { rm -f "$CF_HELPER_SRC"; die 'Cannot build the Cloudflare CIDR allowlist'; }

# Existing .env is trusted as a file, but never source/execute it.
mkdir -p "$NODE_DIR" "$STATE_DIR" "$SNIPPET_DIR" "$SITE_DIR" "$ACME_ROOT" "$BACKUP_DIR"
if [[ -f "$NODE_DIR/.env" ]]; then
  EXISTING_SECRET_KEY=$(env_value SECRET_KEY)
  if [[ -n "$EXISTING_SECRET_KEY" ]]; then
    if [[ -n "$SECRET_KEY" && "$SECRET_KEY" != "$EXISTING_SECRET_KEY" ]]; then
      die 'Provided SECRET_KEY differs from the existing RemnaNode .env. Refusing to replace the node identity.'
    fi
    SECRET_KEY="$EXISTING_SECRET_KEY"
  fi
fi
if [[ -z "$SECRET_KEY" && -r /dev/tty ]]; then
  read -r -s -p 'Remnawave NODE SECRET_KEY (input hidden): ' SECRET_KEY </dev/tty || true
  echo
fi
[[ -n "$SECRET_KEY" ]] || die 'SECRET_KEY missing. Create the node in the panel and provide its secret.'
[[ "$SECRET_KEY" =~ ^[A-Za-z0-9_./+=:-]+$ ]] || die 'SECRET_KEY contains unexpected characters'
PANEL_IP=$(python3 - "$PANEL_IP" <<'PY'
import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1])
if ip.is_unspecified or ip.is_multicast: raise SystemExit('PANEL_IP must be a unicast address')
print(ip)
PY
) || die 'PANEL_IP must be one IPv4 or IPv6 address (not a hostname or CIDR).'

# Generate two per-node Host paths below fixed server-side prefixes.
# The Config Profile remains identical across all nodes: /relay/ and /cache/.
# NOTE: Shared profile (inbound extra) and Host xhttpExtraParams must BOTH use the same placement.
# Real Xray field names are sessionPlacement/sessionKey/seqPlacement/seqKey (NOT sessionIDPlacement/sessionIDKey).
read_manifest_path() {
  local key="$1"
  [[ -f "$STATE_DIR/manifest.env" ]] || return 0
  sed -n "s/^${key}=//p" "$STATE_DIR/manifest.env" | head -n 1
}
generate_path() {
  local prefix="$1" kind="$2"
  python3 - "$prefix" "$kind" <<'PYRAND'
import secrets,sys
prefix,kind=sys.argv[1:]
token=secrets.token_urlsafe(16).rstrip('=')
if kind=='direct':
    tails=(f'api/v2/analytics/{token}/events/',f'service/v3/client/{token}/sync/',f'content/v2/catalog/{token}/metadata/',f'platform/v1/device/{token}/configuration/',f'api/v3/preferences/{token}/state/')
else:
    tails=(f'assets/v3/runtime/{token}/chunks/',f'api/v2/resources/{token}/manifest/',f'service/v3/storage/{token}/index/',f'content/v1/media/{token}/delivery/',f'assets/v2/application/{token}/bundle/')
print(prefix+secrets.choice(tails))
PYRAND
}
[[ "$ROTATE_XHTTP_PATHS" == 0 || "$ROTATE_XHTTP_PATHS" == 1 ]] || die 'ROTATE_XHTTP_PATHS must be 0 or 1'
if [[ "$ROTATE_XHTTP_PATHS" == 1 ]]; then
  XHTTP_PATH=$(generate_path "$XHTTP_PREFIX" direct)
  XHTTP_WARP_PATH=$(generate_path "$XHTTP_WARP_PREFIX" warp)
else
  XHTTP_PATH=${XHTTP_PATH:-$(read_manifest_path XHTTP_PATH)}
  XHTTP_WARP_PATH=${XHTTP_WARP_PATH:-$(read_manifest_path XHTTP_WARP_PATH)}
fi
[[ "$XHTTP_PATH" == "$XHTTP_PREFIX"* ]] || XHTTP_PATH=$(generate_path "$XHTTP_PREFIX" direct)
[[ "$XHTTP_WARP_PATH" == "$XHTTP_WARP_PREFIX"* ]] || XHTTP_WARP_PATH=$(generate_path "$XHTTP_WARP_PREFIX" warp)
[[ "$XHTTP_PATH" != "$XHTTP_WARP_PATH" ]] || die 'XHTTP paths must differ'
[[ "$XHTTP_PATH" =~ ^/relay/[A-Za-z0-9_/-]+/$ ]] || die 'Invalid direct Host path'
[[ "$XHTTP_WARP_PATH" =~ ^/cache/[A-Za-z0-9_/-]+/$ ]] || die 'Invalid WARP Host path'
log 'Shared server prefixes: /relay/ and /cache/; per-node Host paths generated and persisted.'
if [[ "$ROTATE_XHTTP_PATHS" == 1 ]]; then
  warn 'ROTATE_XHTTP_PATHS=1: Host paths changed. Update both Remnawave Hosts and subscriptions before use.'
fi

# Snapshot files before touching a running service.
for f in "$CONF" "$CFACL" "$CDN_SNIP" "$WARP_SNIP" \
         /etc/nginx/sites-enabled/default "$SITE_DIR/index.html" "$SITE_DIR/404.html" \
         "$STATE_DIR/site-meta.json" "$STATE_DIR/manifest.env" \
         "$STATE_DIR/host-settings.txt" "$STATE_DIR/host-settings.json" \
         "$NODE_DIR/docker-compose.yml" "$NODE_DIR/.env" /etc/letsencrypt/renewal-hooks/deploy/krasnaya-nginx-reload.sh \
         /etc/default/ufw /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/ufw.conf \
         /etc/sysctl.d/99-krasnaya-bbr.conf "$CF_HELPER" \
         "$UNIT_DIR/krasnaya-cf-refresh.service" "$UNIT_DIR/krasnaya-cf-refresh.timer"; do
  backup "$f"
done
ROLLBACK=1
install -m 755 "$CF_HELPER_SRC" "$CF_HELPER"
rm -f "$CF_HELPER_SRC"

log 'Generating a distinct website (existing generated site is preserved on reruns)'
python3 - "$SITE_DIR" "$STATE_DIR/site-meta.json" "$DOMAIN" "$REGENERATE_SITE" <<'PYSITE'
import html,json,pathlib,secrets,sys,datetime
out=pathlib.Path(sys.argv[1]); meta_file=pathlib.Path(sys.argv[2]); domain=sys.argv[3]; regenerate=sys.argv[4]=='1'
if meta_file.exists() and (out/'index.html').exists() and not regenerate:
    meta=json.loads(meta_file.read_text(encoding='utf-8'))
    print('Preserving site:',meta['name'],'variant',meta['variant'])
    raise SystemExit(0)
rng=secrets.SystemRandom()
def h(s): return html.escape(str(s))

# (name, kind, headline, description, three sections)
SUBJECTS=[
 ('Atelier','Objects & interiors','Objects made for everyday rituals.','Material-led furniture, useful editions and considered spaces.',('Furniture','Material Studies','Spatial Objects')),
 ('Field Studio','Landscape & planting','A quieter way to grow.','Outdoor spaces imagined around texture, season and local ecology.',('Gardens','Planting','Landscape')),
 ('Mono Press','Independent bookmaking','Printed with intention.','Small-run editions, editorial forms and experimental paper objects.',('Editorial','Print Editions','Binding')),
 ('Form Ceramics','Ceramic objects','Shape is a kind of language.','Explorations of clay, glaze and the beauty of honest materials.',('Tableware','Objects','Surface Studies')),
 ('Stillhouse','Architecture & interiors','Spaces with room to breathe.','Thoughtful spatial ideas shaped by light, balance and purpose.',('Interiors','Concepts','Details')),
 ('Northline Audio','Sound & composition','Make a little room for sound.','Sound design, textured atmospheres and music-led experiments.',('Sound','Composition','Listening')),
 ('Slowlight','Photography & film','Observe the details.','An independent visual practice working with natural light and form.',('Still Life','Editorial','Motion')),
 ('Morrow Goods','Objects for daily life','Designed to stay.','Everyday essentials explored through proportion and clear design.',('Essentials','Objects','Materials')),
 ('Daybreak','Coffee & provisions','Begin with something good.','Small pleasures, warm spaces and a considered daily ritual.',('Coffee','Pantry','Gathering')),
 ('Paperwild','Illustration','Make space for imagination.','An independent studio for expressive image-making and visual worlds.',('Illustration','Stories','Experiments')),
 ('Signal Works','Digital product studio','Make complexity feel simple.','Clear interfaces and systems built around human needs.',('Interfaces','Systems','Prototypes')),
 ('Loom & Line','Textiles','Woven for living.','A study of quiet patterns, texture and everyday form.',('Textiles','Patterns','Editions')),
 ('Tidewater','Ocean-minded apparel','Made to weather well.','Durable garments and goods cut for wind, salt and long days outside.',('Outerwear','Basics','Repairs')),
 ('Kiln & Co.','Glass & lighting','Light, shaped by hand.','Hand-blown glass and lighting pieces made in small batches.',('Lighting','Vessels','Commissions')),
 ('Orchard Row','Seasonal bakery','Bread, slowly.','Long-fermented loaves, seasonal pastry and a short, honest menu.',('Bread','Pastry','Seasonal')),
 ('Quarry','Stone & landscape design','Built to outlast us.','Stone, timber and planting composed into quiet outdoor rooms.',('Paving','Walls','Planting')),
 ('Lumen Lab','Lighting research','Understand light first.','Daylight studies and lighting design for homes, galleries and workplaces.',('Daylight','Galleries','Research')),
 ('Bureau Nord','Graphic design','Order, with a little wit.','Identity, typography and editorial systems for cultural clients.',('Identity','Typography','Editorial')),
 ('Wren & Ash','Woodworking','Joinery you can feel.','Furniture and fittings made from locally milled hardwood.',('Tables','Storage','Fittings')),
 ('Pilot Light','Independent record label','Small runs, big ears.','Limited-edition releases and listening sessions from a tight-knit roster.',('Releases','Artists','Sessions')),
 ('Common Thread','Mending & alteration','Keep it going.','Repair, alteration and reworking of clothes people already love.',('Mending','Alterations','Rework')),
 ('Terrace','Plant studio','Green, but practical.','Hardy plants, planters and care guidance for small city spaces.',('Plants','Planters','Care')),
 ('Halcyon Type','Type foundry','Letters with character.','Original typefaces drawn for text, display and screens.',('Families','Custom','Licensing')),
 ('Meridian Maps','Cartography','Places, carefully drawn.','Hand-finished maps, city plans and wayfinding illustration.',('City Maps','Wayfinding','Prints')),
 ('Basalt','Landscape photography','Quiet places, long light.','Large-format landscape work from northern coasts and high plateaus.',('Coast','Plateau','Prints')),
 ('Fieldnotes Lab','Research & workshops','Curious by method.','Small workshops and research notes on craft, place and making.',('Workshops','Notes','Residencies')),
 ('Juniper & Pine','Natural skincare','Simple, and honest.','Small-batch balms and oils made with short ingredient lists.',('Balms','Oils','Refills')),
 ('Harbor Cycles','Bicycle workshop','Ride it, fix it.','Repairs, custom builds and a few well-chosen parts for city riders.',('Repairs','Builds','Parts')),
 ('Plinth','Gallery & editions','Art, up close.','Exhibitions, editions and conversations with emerging artists.',('Exhibitions','Editions','Programme')),
 ('Candlewick','Home fragrance','Slow evenings.','Hand-poured candles and room sprays in a small, seasonal range.',('Candles','Sprays','Gifting')),
 ('Ledger & Rye','Neighbourhood café','Good food, no rush.','Breakfast, lunch and a long table for whoever shows up.',('Breakfast','Lunch','Events')),
]
# (bg, fg, accent, muted, panel) — mixed light and dark themes
PALETTES=[
 ('#f5f1e8','#0e2030','#b0d2c4','#4a5c68','#e8e2d3'),('#f6efe7','#2a1c22','#df957d','#6b5058','#ecdfd2'),
 ('#eaf1e9','#152f2a','#d8a85d','#45605a','#dbe6d9'),('#f1eff7','#211d38','#b7a4e8','#5a5575','#e4e0f0'),
 ('#f6efe7','#3c2b22','#a5bdc8','#6c5748','#ebe0d4'),('#f4f0e9','#17212d','#eab477','#4c5b6b','#e7e1d6'),
 ('#edf0ea','#27302c','#a7b9a4','#56625b','#dfe4dc'),('#f7f2ec','#26212f','#dcbdc9','#5d5068','#ece4db'),
 ('#fafaf7','#1b1b1b','#e4572e','#666666','#efefea'),('#f2f6f8','#0b2239','#59a5d8','#4d6479','#e2ebf0'),
 ('#fbf4e4','#3a2d12','#c8553d','#725f3d','#f1e6cc'),('#eef3ee','#14281d','#8fb996','#4b6455','#dfe9df'),
 ('#101820','#f2ead7','#f2a65a','#aab3b8','#1b2631'),('#16181d','#eceae4','#c0a5ff','#a3a5ad','#22252c'),
 ('#0f2622','#e9efe6','#e9c46a','#a1b8b0','#183630'),('#1c1417','#f4e9e4','#ff8e72','#bfa9a6','#291d21'),
 ('#12202e','#f1efe6','#7fd1b9','#a7b5c2','#1c2e40'),('#f3e9dc','#2e1f1a','#6b8f71','#6d5a4e','#e7d9c6'),
]
FONTS=[
 ('-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif','-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif'),
 ('Georgia,"Times New Roman",Times,serif','-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif'),
 ('"Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif','Georgia,"Times New Roman",serif'),
 ('"Avenir Next",Avenir,"Trebuchet MS",Verdana,sans-serif','"Avenir Next",Avenir,"Trebuchet MS",Verdana,sans-serif'),
 ('"Gill Sans","Gill Sans MT",Calibri,"Trebuchet MS",sans-serif','"Gill Sans","Gill Sans MT",Calibri,sans-serif'),
 ('ui-monospace,"SF Mono",Menlo,Consolas,monospace','-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif'),
 ('"Palatino Linotype",Palatino,"Book Antiqua",serif','"Palatino Linotype",Palatino,"Book Antiqua",serif'),
]
ARTS={
 'orbs':'radial-gradient(circle at 30% 38%,var(--ac) 0 21%,transparent 21.5%),radial-gradient(circle at 68% 66%,var(--pn) 0 29%,transparent 29.5%),var(--fg)',
 'stripes':'repeating-linear-gradient(__ANG__deg,var(--ac) 0 26px,var(--fg) 26px 52px)',
 'dots':'radial-gradient(var(--ac) 2.5px,transparent 3px) 0 0/24px 24px,var(--pn)',
 'sun':'radial-gradient(circle at 50% 62%,var(--ac) 0 17%,transparent 17.5% 25%,var(--ac) 25.5% 27%,transparent 27.5% 36%,var(--ac) 36.5% 37.5%,transparent 38%),var(--fg)',
 'arches':'radial-gradient(ellipse at 50% 100%,var(--ac) 0 38%,transparent 38.5%),radial-gradient(ellipse at 50% 100%,var(--pn) 0 68%,transparent 68.5%),var(--fg)',
 'blocks':'linear-gradient(120deg,var(--ac) 0 36%,transparent 36%),linear-gradient(60deg,var(--pn) 0 44%,transparent 44%),var(--fg)',
 'grid':'linear-gradient(var(--ac) 1px,transparent 1px) 0 0/40px 40px,linear-gradient(90deg,var(--ac) 1px,transparent 1px) 0 0/40px 40px,var(--fg)',
}
BLURBS=['Form, function and a little curiosity.','Measured details, lasting impressions.','A study in texture and balance.','Made slowly, in small numbers.','Built around real use, not trends.','Simple ideas, carefully finished.','Quiet work with a clear point of view.','Starts with a sketch and a long walk.','Shaped by season, light and place.','Honest materials, patient hands.']
QUOTES=['Good work is mostly careful attention.','We make fewer things, and look after them longer.','Start small. Keep what works. Edit the rest.','Nothing here is rushed, and it shows.','A practice built around curiosity and patience.']
CITIES=['Lisbon','Tallinn','Rotterdam','Turku','Ghent','Porto','Brno','Gdańsk','Bergen','Riga','Lyon','Antwerp','Kraków','Aarhus','Trieste','Utrecht']
NAVS=[('Work','About','Contact'),('Studio','Journal','Contact'),('Projects','Notes','Hello'),('Index','About','Say hello'),('Selected','Practice','Contact'),('Collection','Story','Visit')]

def lum(hexc):
    r,g,b=[int(hexc[i:i+2],16)/255 for i in (1,3,5)]
    f=lambda c:c/12.92 if c<=0.03928 else ((c+0.055)/1.055)**2.4
    return 0.2126*f(r)+0.7152*f(g)+0.0722*f(b)
def rgba(c,a): return 'rgba(%d,%d,%d,%s)'%(int(c[1:3],16),int(c[3:5],16),int(c[5:7],16),a)
def on(bg): return '#111111' if lum(bg)>0.35 else '#ffffff'

name,kind,headline,desc,items=rng.choice(SUBJECTS)
bg,fg,ac,mu,pn=rng.choice(PALETTES)
hfont,bfont=rng.choice(FONTS)
layout=rng.choice(['split','editorial','centered','stacked','minimal'])
art=rng.choice(list(ARTS)); sect=rng.choice(['tiles','list','columns','quote'])
header=rng.choice(['rule','plain','pill']); radius=rng.choice(['0','2px','10px','22px'])
case=rng.choice(['none','none','uppercase']); hw=rng.choice([400,500,600,700,800]); ls=rng.choice(['-.04em','-.06em','-.02em','0'])
if hfont.startswith('ui-monospace'): ls='-.03em'
nav=rng.choice(NAVS); city=rng.choice(CITIES); id_=secrets.token_hex(5)
suffix=rng.choice(['Studio','Works','Collective','Office','Journal','Lab','& Co.','House'])
brand=name if rng.choice([True,False]) or name.endswith(('Co.','Lab','Works')) else name+' '+suffix
year=datetime.datetime.now().year; blurbs=rng.sample(BLURBS,3); quote=rng.choice(QUOTES)
eyebrow=rng.choice([kind,f'{kind} · {city}',f'Est. {rng.randint(2009,2023)} · {city}',f'{city} — {kind}'])
cta=rng.choice(['Explore the work','See selected work','Take a look','Read more','View the index'])
hsize={'minimal':'clamp(3.2rem,10vw,9rem)','centered':'clamp(2.8rem,7vw,6.4rem)','stacked':'clamp(2.6rem,6vw,5.6rem)'}.get(layout,'clamp(2.6rem,6.2vw,6.2rem)')
fav='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="%d" fill="%s"/><text x="16" y="22" font-size="18" text-anchor="middle" font-family="Georgia,serif" fill="%s">%s</text></svg>'%(rng.choice([4,16]),ac,on(ac),h(brand[0]))
fav_uri='data:image/svg+xml,'+fav.replace('<','%3C').replace('>','%3E').replace('#','%23').replace('"',"'")

lead=f'<div class="hero-content"><p class="eyebrow">{h(eyebrow)}</p><h1>{h(headline)}</h1><p class="intro">{h(desc)}</p><a class="anchor" href="#work">{h(cta)} <span aria-hidden="true">↗</span></a></div>'
artdiv='<div class="hero-art" aria-hidden="true"><span>'+h(brand.upper())+' · '+id_[:4].upper()+'</span></div>'
if layout=='minimal': hero=f'<section class="hero layout-minimal">{lead}</section>'
elif layout=='editorial': hero=f'<section class="hero layout-editorial">{artdiv}{lead}</section>'
elif layout=='stacked': hero=f'<section class="hero layout-stacked">{artdiv}{lead}</section>'
else: hero=f'<section class="hero layout-{layout}">{lead}{artdiv}</section>'

if sect=='tiles':
    body=''.join(f'<article class="tile t{i}"><span class="num">0{i}</span><h3>{h(it)}</h3><p>{h(blurbs[i-1])}</p></article>' for i,it in enumerate(items,1))
    body=f'<div class="tiles">{body}</div>'
elif sect=='list':
    body=''.join(f'<li><span class="num">0{i}</span><h3>{h(it)}</h3><p>{h(blurbs[i-1])}</p></li>' for i,it in enumerate(items,1))
    body=f'<ol class="rows">{body}</ol>'
elif sect=='columns':
    body=''.join(f'<div class="col"><h3>{h(it)}</h3><p>{h(blurbs[i-1])} {h(desc)}</p></div>' for i,it in enumerate(items,1))
    body=f'<div class="cols">{body}</div>'
else:
    body=f'<blockquote class="quote">“{h(quote)}”</blockquote><ul class="facts">'+''.join(f'<li>{h(it)}</li>' for it in items)+'</ul>'
sect_title=rng.choice(['Selected work','Ideas in progress','What we do','Recent','Practice','Currently'])
about_t=rng.choice(['About','Studio notes','The practice'])
about=f'<section id="about" class="about"><h2>{h(about_t)}</h2><p>{h(name)} is an independent practice based in {h(city)}. {h(desc)}</p></section>'
contact=f'<section id="contact" class="contact"><h2>{h(nav[2])}</h2><p>Enquiries: hello@{h(domain)}</p></section>'
links=''.join(f'<a href="#{a}">{h(t)}</a>' for t,a in zip(nav,('work','about','contact')))
footer=rng.choice([f'© {year} {h(brand)}',f'{h(brand)} · {h(city)}',f'© {year} · {h(city)}'])

css='''
:root{--bg:__BG__;--fg:__FG__;--ac:__AC__;--mu:__MU__;--pn:__PN__;--onac:__ONAC__;--ln:__LN__;--r:__R__}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.65 __BODY__}
a{color:inherit}a:hover{text-decoration:underline}::selection{background:var(--ac);color:var(--onac)}
.shell{max-width:1280px;margin:auto;padding:0 6vw}
.top{display:flex;align-items:center;justify-content:space-between;gap:20px;height:92px}
.top.rule{border-bottom:1px solid var(--ln)}.top.pill nav{background:var(--pn);padding:8px 18px;border-radius:999px}
.brand{font-family:__HEAD__;font-size:1.45rem;font-weight:__HW__;letter-spacing:-.03em;text-decoration:none}
nav{display:flex;gap:26px;font-size:.82rem;letter-spacing:.08em;text-transform:uppercase}nav a{text-decoration:none}nav a:hover{text-decoration:underline}
.hero{display:grid;gap:min(6vw,72px);align-items:center;padding:72px 0 88px}
.layout-split{grid-template-columns:1.1fr .9fr}.layout-editorial{grid-template-columns:.9fr 1.1fr}
.layout-centered{text-align:center;justify-items:center}.layout-centered .hero-art{width:min(560px,92%);min-height:260px}.layout-centered .intro{margin-inline:auto}
.layout-stacked{grid-template-columns:1fr}.layout-stacked .hero-art{min-height:240px;order:-1}.layout-minimal{grid-template-columns:1fr;padding:96px 0 110px}.layout-minimal .intro{max-width:620px}
.eyebrow{font-size:.7rem;letter-spacing:.2em;font-weight:700;text-transform:uppercase;color:var(--mu);margin:0}
h1{font-family:__HEAD__;font-size:__HSIZE__;line-height:1.02;letter-spacing:__LS__;font-weight:__HW__;text-transform:__CASE__;margin:28px 0}
.intro{max-width:480px;font-size:1.1rem;color:var(--mu);margin:0}
.anchor{display:inline-block;margin-top:38px;padding:12px 22px;background:var(--ac);color:var(--onac);border-radius:var(--r);font-size:.8rem;font-weight:700;letter-spacing:.09em;text-transform:uppercase;text-decoration:none}
.hero-art{position:relative;min-height:440px;background:__ART__;border-radius:var(--r);overflow:hidden}
.hero-art span{position:absolute;left:24px;bottom:20px;font-size:.62rem;letter-spacing:.3em;color:var(--bg);mix-blend-mode:difference}
section h2{font-family:__HEAD__;font-size:clamp(1.8rem,3.4vw,3.2rem);font-weight:__HW__;letter-spacing:__LS__;line-height:1.1;margin:0 0 24px}
.section-top{border-top:1px solid var(--ln);padding:56px 0 18px}
.tiles{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:18px;padding:12px 0 84px}
.tile{background:var(--pn);padding:30px;min-height:240px;display:flex;flex-direction:column;border-radius:var(--r)}.tile.t2{background:var(--ac);color:var(--onac)}.tile.t3{background:var(--fg);color:var(--bg)}
.tile h3{font-size:1.6rem;margin:auto 0 10px;font-family:__HEAD__}.tile p{font-size:.88rem;opacity:.8;margin:0}.num{font-size:.7rem;letter-spacing:.15em;opacity:.7}
.rows{list-style:none;margin:0;padding:6px 0 84px}.rows li{display:grid;grid-template-columns:70px 1fr 1.2fr;gap:20px;align-items:baseline;padding:22px 0;border-top:1px solid var(--ln)}.rows h3{margin:0;font-size:1.5rem;font-family:__HEAD__}.rows p{margin:0;color:var(--mu)}
.cols{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:36px;padding:12px 0 84px}.col{border-top:3px solid var(--ac);padding-top:16px}.col h3{margin:0 0 8px;font-size:1.35rem;font-family:__HEAD__}.col p{margin:0;color:var(--mu);font-size:.95rem}
.quote{font-family:__HEAD__;font-size:clamp(1.6rem,3.6vw,3rem);line-height:1.25;max-width:20em;margin:10px 0 22px;letter-spacing:-.02em}.facts{list-style:none;display:flex;gap:12px;flex-wrap:wrap;padding:0 0 84px;margin:0}.facts li{background:var(--pn);padding:8px 16px;border-radius:999px;font-size:.85rem}
.about,.contact{border-top:1px solid var(--ln);padding:48px 0 54px;display:grid;grid-template-columns:1fr 2fr;gap:24px}.about p,.contact p{margin:0;max-width:560px;color:var(--mu)}
.bottom{border-top:1px solid var(--ln);padding:26px 0 40px;font-size:.78rem;color:var(--mu);display:flex;justify-content:space-between;gap:16px}
@media(max-width:850px){.hero,.layout-split,.layout-editorial{grid-template-columns:1fr;padding:48px 0 60px}.hero-art{min-height:300px}.tiles,.cols{grid-template-columns:1fr}.rows li{grid-template-columns:44px 1fr}.rows p{grid-column:2}.about,.contact{grid-template-columns:1fr}.top{height:72px}nav{gap:14px}}
'''
art_css=ARTS[art].replace('__ANG__',str(rng.choice([45,90,135])))
for k,v in {'__BG__':bg,'__FG__':fg,'__AC__':ac,'__MU__':mu,'__PN__':pn,'__ONAC__':on(ac),'__LN__':rgba(fg,'.18'),'__R__':radius,'__BODY__':bfont,'__HEAD__':hfont,'__HW__':str(hw),'__LS__':ls,'__CASE__':case,'__HSIZE__':hsize,'__ART__':art_css}.items():
    css=css.replace(k,v)
head=f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="theme-color" content="{bg}"><title>{h(brand)} — {h(kind)}</title><meta name="description" content="{h(desc)}"><link rel="icon" href="{fav_uri}"><style>{css}</style></head>'
page=head+f'<body><div class="shell"><header class="top {header}"><a class="brand" href="/">{h(brand)}</a><nav>{links}</nav></header><main>{hero}<section id="work" class="section-top"><h2>{h(sect_title)}</h2></section>{body}{about}{contact}</main><footer class="bottom"><span>{footer}</span><span>{h(kind)}</span></footer></div></body></html>'
(out/'index.html').write_text(page,encoding='utf-8')
(out/'404.html').write_text(head+f'<body><div class="shell"><header class="top {header}"><a class="brand" href="/">{h(brand)}</a></header><main class="hero layout-minimal"><div class="hero-content"><p class="eyebrow">404</p><h1>Page not found.</h1><a class="anchor" href="/">Back home</a></div></main></div></body></html>',encoding='utf-8')
meta={'id':id_,'name':brand,'variant':f'{layout}/{art}/{sect}','category':kind,'created_at':datetime.datetime.now(datetime.timezone.utc).isoformat()}
meta_file.write_text(json.dumps(meta,indent=2,ensure_ascii=False),encoding='utf-8')
print('Generated:',brand,'|',kind,'|',meta['variant'])
PYSITE
chmod 755 "$SITE_DIR"
chmod 644 "$SITE_DIR/index.html" "$SITE_DIR/404.html"

log 'Writing Cloudflare CIDR allowlist and shared-prefix XHTTP reverse proxy locations'
printf '%s\n' "$CF_ALLOW_TXT" > "$CFACL"
chmod 644 "$CFACL"
write_xhttp_location() {
  local prefix="$1" port="$2" file="$3"
  cat > "$file" <<EOF
location ^~ ${prefix} {
    include ${CFACL};
    client_max_body_size 0;
    client_body_buffer_size 2m;
    grpc_buffer_size 64k;
    grpc_set_header Host \$host;
    grpc_set_header X-Real-IP \$http_cf_connecting_ip;
    grpc_set_header X-Forwarded-For \$http_cf_connecting_ip;
    grpc_set_header CF-Connecting-IP \$http_cf_connecting_ip;
    client_body_timeout 5m;
    grpc_read_timeout 315s;
    grpc_send_timeout 5m;
    grpc_socket_keepalive on;
    grpc_pass grpc://127.0.0.1:${port};
}
EOF
  chmod 644 "$file"
}
write_xhttp_location "$XHTTP_PREFIX" "$XHTTP_PORT" "$CDN_SNIP"
write_xhttp_location "$XHTTP_WARP_PREFIX" "$XHTTP_WARP_PORT" "$WARP_SNIP"

log 'Configuring TLS certificate and website'
rm -f /etc/nginx/sites-enabled/default
mkdir -p "$ACME_ROOT/.well-known/acme-challenge"
chmod o+rx /var/www
chmod 755 "$ACME_ROOT" "$ACME_ROOT/.well-known" "$ACME_ROOT/.well-known/acme-challenge"
if [[ ! -s "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" || ! -s "/etc/letsencrypt/live/$DOMAIN/privkey.pem" ]]; then
  # Initial HTTP-only config for ACME without SSL certificate.
  cat > "$CONF" <<EOF
server {
    listen 80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; }
    location / { return 404; }
}
EOF
  nginx -t || die 'Nginx pre-ACME test failed'
  systemctl enable --now nginx >/dev/null
  systemctl reload nginx
  CERT_ARGS=(--register-unsafely-without-email)
  [[ -n "$EMAIL" ]] && CERT_ARGS=(--email "$EMAIL")
  if ! certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" \
      --non-interactive --agree-tos "${CERT_ARGS[@]}"; then
    die 'Certificate issuance failed. Check Cloudflare proxied DNS, port 80 and HTTPS redirect rules. Restoring previous nginx config.'
  fi
fi

NGINX_VER=$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9][0-9.]*\).*|\1|p')
ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }
if ver_ge "${NGINX_VER:-0}" 1.25.1; then
  LISTEN_443='listen 443 ssl;'; HTTP2_LINE='http2 on;'
else
  LISTEN_443='listen 443 ssl http2;'; HTTP2_LINE=''
fi
STRICT=$STRICT_SNI
if [[ "$STRICT" == 1 ]] && ! ver_ge "${NGINX_VER:-0}" 1.19.4; then
  warn "Nginx ${NGINX_VER:-unknown} lacks ssl_reject_handshake (needs 1.19.4+); STRICT_SNI disabled."
  STRICT=0
fi
# Throughput tuning for long XHTTP streams behind Cloudflare.
# Old defaults recycle an HTTP/2 connection after 100-1000 requests, which stalls packet-up transfers.
if ver_ge "${NGINX_VER:-0}" 1.19.7; then
  H2_TUNE='keepalive_requests 100000;'
else
  H2_TUNE='keepalive_requests 100000;
    http2_max_requests 100000;'
fi
if [[ "$STRICT" == 1 ]]; then
  # Unknown SNI (e.g. someone scanning the raw IP) gets no certificate and no site.
  CATCHALL="server {
    ${LISTEN_443%;} default_server;
    server_name _;
    ssl_reject_handshake on;
}"
  DOMAIN_LISTEN=$LISTEN_443
else
  CATCHALL=''
  DOMAIN_LISTEN="${LISTEN_443%;} default_server;"
fi
cat > "$CONF" <<EOF
server_tokens off;
server {
    listen 80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root ${ACME_ROOT}; }
    location / { return 301 https://${DOMAIN}\$request_uri; }
}
${CATCHALL}
server {
    ${DOMAIN_LISTEN}
    ${HTTP2_LINE}
    server_name ${DOMAIN};
    keepalive_timeout 300s;
    ${H2_TUNE}
    http2_chunk_size 32k;
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    root ${SITE_DIR};
    index index.html;
    error_page 404 /404.html;
    access_log off;
    include ${SNIPPET_DIR}/xhttp-location.conf;
    include ${SNIPPET_DIR}/xhttp-warp-location.conf;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
nginx -t || die 'Final Nginx config test failed'
systemctl enable --now nginx >/dev/null
systemctl reload nginx

# Certificate auto-renewal with safe reload after successful issuance.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/krasnaya-nginx-reload.sh <<'EOF'
#!/bin/sh
nginx -t >/dev/null 2>&1 && systemctl reload nginx
EOF
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/krasnaya-nginx-reload.sh
if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then systemctl enable --now certbot.timer >/dev/null 2>&1 || true; fi

cat > "$UNIT_DIR/krasnaya-cf-refresh.service" <<'EOF'
[Unit]
Description=Refresh Cloudflare CIDR allowlist for Nginx
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/krasnaya-cf-refresh
EOF
cat > "$UNIT_DIR/krasnaya-cf-refresh.timer" <<'EOF'
[Unit]
Description=Weekly Cloudflare CIDR allowlist refresh

[Timer]
OnCalendar=weekly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF
chmod 644 "$UNIT_DIR/krasnaya-cf-refresh.service" "$UNIT_DIR/krasnaya-cf-refresh.timer"

log 'Deploying RemnaNode using Docker Compose (preserving existing files when present)'
DOCKER_CHANGED=1
if [[ ! -f "$NODE_DIR/.env" ]]; then
  cat > "$NODE_DIR/.env" <<EOF
NODE_PORT=${NODE_PORT}
SECRET_KEY=${SECRET_KEY}
EOF
  chmod 600 "$NODE_DIR/.env"
else
  if ! grep -q '^NODE_PORT=' "$NODE_DIR/.env"; then printf '\nNODE_PORT=%s\n' "$NODE_PORT" >> "$NODE_DIR/.env"; fi
  if ! grep -q '^SECRET_KEY=' "$NODE_DIR/.env"; then printf 'SECRET_KEY=%s\n' "$SECRET_KEY" >> "$NODE_DIR/.env"; fi
  chmod 600 "$NODE_DIR/.env"
fi
if [[ ! -f "$NODE_DIR/docker-compose.yml" ]]; then
  cat > "$NODE_DIR/docker-compose.yml" <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ${NODE_IMAGE}
    network_mode: host
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    environment:
      NODE_PORT: "\${NODE_PORT}"
      SECRET_KEY: "\${SECRET_KEY}"
EOF
  chmod 600 "$NODE_DIR/docker-compose.yml"
else
  grep -Eq "container_name:[[:space:]]*['\"]?remnanode['\"]?([[:space:]]|$)|^[[:space:]]*remnanode:" "$NODE_DIR/docker-compose.yml" || die 'Existing docker-compose.yml is not recognized as the RemnaNode compose file; it was preserved. Review it manually.'
  log 'Existing docker-compose.yml preserved.'
fi
NEED_PULL=$PULL_NODE_IMAGE
if [[ "$NEED_PULL" != 1 ]]; then
  while read -r img; do
    [[ -z "$img" ]] || docker image inspect "$img" >/dev/null 2>&1 || NEED_PULL=1
  done < <(cd "$NODE_DIR" && docker compose config --images 2>/dev/null)
fi
if [[ "$NEED_PULL" == 1 ]]; then (cd "$NODE_DIR" && docker compose pull); fi
(cd "$NODE_DIR" && docker compose up -d)
sleep 5
if [[ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' remnanode 2>/dev/null || true)" != 'true false' ]]; then
  docker logs --tail 30 remnanode >&2 || true
  die 'remnanode container is not running stably (see logs above). Check SECRET_KEY and NODE_PORT.'
fi
for _ in $(seq 1 15); do
  ss -Hltn "( sport = :${NODE_PORT} )" 2>/dev/null | grep -q . && break
  sleep 1
done
ss -Hltn "( sport = :${NODE_PORT} )" 2>/dev/null | grep -q . || warn "Nothing listens on NODE_PORT ${NODE_PORT} yet; check: docker logs remnanode"

log 'Applying UFW policy: Remnawave panel only on node management port'
if ufw status | grep -q '^Status: active'; then
  UFW_WAS_ACTIVE=1
else
  UFW_WAS_ACTIVE=0
fi

# Detect active SSH listener(s) so enabling UFW cannot lock out administration.
SSH_PORTS=()
add_ssh_port() {
  local p="$1" q
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  (( p >= 1 && p <= 65535 )) || return 0
  for q in "${SSH_PORTS[@]:-}"; do [[ "$q" == "$p" ]] && return 0; done
  SSH_PORTS+=("$p")
}
if [[ -n "$SSH_PORT" ]]; then
  add_ssh_port "$SSH_PORT"
fi
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ssh_client _ssh_client_port _ssh_server _ssh_server_port <<< "$SSH_CONNECTION"
  add_ssh_port "${_ssh_server_port:-}"
fi
if command -v sshd >/dev/null 2>&1; then
  while read -r p; do add_ssh_port "$p"; done < <(sshd -T 2>/dev/null | awk '$1=="port" {print $2}')
fi
if ((${#SSH_PORTS[@]} == 0)); then
  while read -r p; do add_ssh_port "$p"; done < <(
    ss -Hltpn 2>/dev/null | awk '/sshd/ {v=$4; sub(/^.*:/,"",v); if (v ~ /^[0-9]+$/) print v}'
  )
fi
if ((${#SSH_PORTS[@]} == 0)); then
  add_ssh_port 22
fi
for p in "${SSH_PORTS[@]}"; do
  [[ "$p" != "$NODE_PORT" ]] || die "SSH also listens on NODE_PORT $NODE_PORT. Refusing to restrict this port to PANEL_IP and lock out SSH; move SSH to another port first."
done

UFW_CHANGED=1
IPV6_WAS_DISABLED=0
# Ensure IPv6 is filtered too; otherwise an IPv6 listener could bypass the IPv4 policy.
if [[ -f /etc/default/ufw ]] && grep -q '^IPV6=no$' /etc/default/ufw; then
  sed -i 's/^IPV6=no$/IPV6=yes/' /etc/default/ufw
  IPV6_WAS_DISABLED=1
fi

# Preserve access to SSH, web, and REALITY before enabling/reloading the firewall.
for p in "${SSH_PORTS[@]}"; do ufw allow "${p}/tcp" >/dev/null; done
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow "${REALITY_PORT}/tcp" >/dev/null
ufw allow "${REALITY_WARP_PORT}/tcp" >/dev/null
# Reload only after SSH allowances have been written, so enabling IPv6 cannot
# briefly drop an existing IPv6 SSH session.
if [[ "$UFW_WAS_ACTIVE" == 1 && "$IPV6_WAS_DISABLED" == 1 ]]; then
  ufw reload >/dev/null
fi

# Check the effective order separately for TCP/UDP and IPv4/IPv6.
POLICY_OK=0
if [[ "$UFW_WAS_ACTIVE" == 1 ]]; then
  if ufw status numbered | python3 -c '
import ipaddress,re,sys
port,panel=sys.argv[1],sys.argv[2]
panel_family=ipaddress.ip_address(panel).version
rows={(proto,fam):[] for proto in ("tcp","udp") for fam in (4,6)}
for line in sys.stdin:
    m=re.match(r"^\[\s*\d+\]\s+(\d+)[/:](tcp|udp)(\s+\(v6\))?\s+(ALLOW|DENY|REJECT)(?:\s+(IN|OUT|FWD))?\s+(.+)$",line.strip())
    if not m: continue
    dest,proto,v6mark,action,direction,source=m.groups()
    if direction not in (None,"IN") or dest != port: continue
    family=6 if v6mark else 4
    source=re.sub(r"\s+\(v6\)$","",source).strip()
    rows[(proto,family)].append((action,source))
for proto in ("tcp","udp"):
    allowed=rows[(proto,panel_family)]
    denied=rows[(proto,10-panel_family)]
    if not allowed or allowed[0] != ("ALLOW",panel): raise SystemExit(1)
    if not any(a=="DENY" and s=="Anywhere" for a,s in allowed[1:]): raise SystemExit(1)
    if not denied or denied[0] != ("DENY","Anywhere"): raise SystemExit(1)
raise SystemExit(0)
' "$NODE_PORT" "$PANEL_IP"; then
    POLICY_OK=1
  fi
fi

if [[ "$POLICY_OK" != 1 ]]; then
  # Add temporary broad denies first. Then put the panel's TCP and UDP allows
  # above them. This avoids rule-order ambiguity when UFW expands dual-protocol
  # rules into separate TCP/UDP entries.
  ufw insert 1 deny "${NODE_PORT}/tcp" >/dev/null
  ufw insert 2 deny "${NODE_PORT}/udp" >/dev/null
  ufw insert 1 allow proto tcp from "$PANEL_IP" to any port "$NODE_PORT" >/dev/null
  ufw insert 2 allow proto udp from "$PANEL_IP" to any port "$NODE_PORT" >/dev/null
fi

if [[ "$UFW_WAS_ACTIVE" != 1 ]]; then
  ufw --force enable >/dev/null
fi

# Remove old broad or duplicate ALLOW rules for NODE_PORT. Keep one TCP and
# one UDP allow for PANEL_IP only; all deny rules remain in place.
mapfile -t STALE_NODE_ALLOW_RULES < <(
  ufw status numbered | python3 -c '
import ipaddress,re,sys
port,panel=sys.argv[1],sys.argv[2]
panel_family=ipaddress.ip_address(panel).version
kept=set()
for line in sys.stdin:
    m=re.match(r"^\[\s*(\d+)\]\s+(\d+)(?:[/:](tcp|udp))?(\s+\(v6\))?\s+(ALLOW|DENY|REJECT)(?:\s+(IN|OUT|FWD))?\s+(.+)$",line.strip())
    if not m: continue
    number,dest,proto,v6mark,action,direction,source=m.groups()
    if direction not in (None,"IN") or dest != port or action != "ALLOW": continue
    family=6 if v6mark else 4
    source=re.sub(r"\s+\(v6\)$","",source).strip()
    key=(proto,family)
    if proto in ("tcp","udp") and family==panel_family and source==panel and key not in kept:
        kept.add(key)
    else:
        print(number)
' "$NODE_PORT" "$PANEL_IP" | sort -rn
)
for rule_number in "${STALE_NODE_ALLOW_RULES[@]}"; do
  [[ -n "$rule_number" ]] && ufw --force delete "$rule_number" >/dev/null
done

UFW_STATUS=$(ufw status numbered)
printf '%s\n' "$UFW_STATUS" | python3 -c '
import ipaddress,re,sys
port,panel=sys.argv[1],sys.argv[2]
panel_family=ipaddress.ip_address(panel).version
rows={(proto,fam):[] for proto in ("tcp","udp") for fam in (4,6)}
for line in sys.stdin:
    m=re.match(r"^\[\s*\d+\]\s+(\d+)[/:](tcp|udp)(\s+\(v6\))?\s+(ALLOW|DENY|REJECT)(?:\s+(IN|OUT|FWD))?\s+(.+)$",line.strip())
    if not m: continue
    dest,proto,v6mark,action,direction,source=m.groups()
    if direction not in (None,"IN") or dest != port: continue
    family=6 if v6mark else 4
    source=re.sub(r"\s+\(v6\)$","",source).strip()
    rows[(proto,family)].append((action,source))
errors=[]
for proto in ("tcp","udp"):
    allowed=rows[(proto,panel_family)]
    denied=rows[(proto,10-panel_family)]
    if not allowed or allowed[0] != ("ALLOW",panel): errors.append(f"{proto}: panel allow is not first for IPv{panel_family}")
    elif not any(a=="DENY" and s=="Anywhere" for a,s in allowed[1:]): errors.append(f"{proto}: no later deny for other IPv{panel_family} sources")
    if not denied or denied[0] != ("DENY","Anywhere"): errors.append(f"{proto}: IPv{10-panel_family} is not denied first")
if errors:
    print("UFW policy verification failed:",*errors,sep="\\n",file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(0)
' "$NODE_PORT" "$PANEL_IP" || die 'UFW did not install the required panel-only NODE_PORT policy.'

if [[ "$ENABLE_BBR" == 1 ]]; then
  modprobe tcp_bbr >/dev/null 2>&1 || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    cat > /etc/sysctl.d/99-krasnaya-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-krasnaya-bbr.conf >/dev/null 2>&1 || warn 'Could not apply BBR sysctl'
  else
    warn 'BBR unavailable on this kernel'
  fi
fi

cat > "$STATE_DIR/manifest.env" <<EOF
DOMAIN=${DOMAIN}
PANEL_IP=${PANEL_IP}
NODE_PORT=${NODE_PORT}
REALITY_PORT=${REALITY_PORT}
REALITY_WARP_PORT=${REALITY_WARP_PORT}
XHTTP_PORT=${XHTTP_PORT}
XHTTP_WARP_PORT=${XHTTP_WARP_PORT}
XHTTP_PATH=${XHTTP_PATH}
XHTTP_WARP_PATH=${XHTTP_WARP_PATH}
EOF
chmod 600 "$STATE_DIR/manifest.env"

log 'Generating per-node Host values (no Mapper files)'
python3 - "$DOMAIN" "$XHTTP_PATH" "$XHTTP_WARP_PATH" "$STATE_DIR" <<'PYHOSTS'
import json,pathlib,sys
from datetime import datetime,timezone

domain,direct_path,warp_path,state=sys.argv[1:]
out=pathlib.Path(state)
extra={
    'noGRPCHeader':False,
    'xPaddingBytes':'100-1000',
    'scMaxEachPostBytes':1000000,
    'scStreamUpServerSecs':'20-80',
    'sessionPlacement':'query',
    'sessionKey':'x_session',
    'seqPlacement':'query',
    'seqKey':'x_seq'
}
base={
    'address':domain,
    'port':443,
    'securityLayer':'TLS',
    'sni':domain,
    'host':domain,
    'alpn':'h2',
    'fingerprint':'chrome',
    'xhttpExtraParams':extra
}
hosts={
    'generatedAt':datetime.now(timezone.utc).isoformat(),
    'note':'Reference values for Remnawave Hosts. No Mapper is required.',
    'hosts':[
        dict(base, remark=f'{domain} CDN Direct', inboundTag='VLESS_XHTTP_CDN', path=direct_path),
        dict(base, remark=f'{domain} CDN WARP', inboundTag='VLESS_XHTTP_CDN_WARP', path=warp_path)
    ]
}
(out/'host-settings.json').write_text(json.dumps(hosts,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
(out/'host-settings.json').chmod(0o600)

lines=[
    'KRASNAYA VPN — REMNAWAVE HOST SETTINGS',
    'Generated: '+datetime.now(timezone.utc).isoformat(),
    'Domain: '+domain,
    '',
    'HOST 1 — CDN DIRECT',
    'Inbound: VLESS_XHTTP_CDN',
    'Address: '+domain,
    'Port: 443',
    'Security Layer: TLS',
    'Transport: XHTTP (inherited from inbound)',
    'SNI: '+domain,
    'Host: '+domain,
    'ALPN: h2',
    'Fingerprint: chrome',
    'Path: '+direct_path,
    'Mode: auto (inherited from inbound)',
    'XHTTP Extra Params (paste as JSON into the Host field):',
    json.dumps(extra,ensure_ascii=False,indent=2),
    '',
    'HOST 2 — CDN WARP',
    'Inbound: VLESS_XHTTP_CDN_WARP',
    'Address: '+domain,
    'Port: 443',
    'Security Layer: TLS',
    'Transport: XHTTP (inherited from inbound)',
    'SNI: '+domain,
    'Host: '+domain,
    'ALPN: h2',
    'Fingerprint: chrome',
    'Path: '+warp_path,
    'Mode: auto (inherited from inbound)',
    'XHTTP Extra Params (paste as JSON into the Host field):',
    json.dumps(extra,ensure_ascii=False,indent=2),
    '',
    'No Mapper files are required.',
    'Set Path and XHTTP Extra Params directly in each Remnawave Host.',
    'Enable both inbounds on this node and in the relevant Internal Squad.'
]
(out/'host-settings.txt').write_text('\n'.join(lines)+'\n',encoding='utf-8')
(out/'host-settings.txt').chmod(0o600)
PYHOSTS

nginx -t >/dev/null 2>&1 || die 'nginx -t failed'
curl_code() {
  curl -sS --resolve "${DOMAIN}:443:127.0.0.1" --connect-timeout 4 --max-time 10 -o /dev/null -w '%{http_code}' "https://${DOMAIN}$1" 2>/dev/null || printf 000
}
SITE_CODE=$(curl_code /); ACL1=$(curl_code "$XHTTP_PREFIX"); ACL2=$(curl_code "$XHTTP_WARP_PREFIX")
EXTRA_JSON=$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["hosts"][0]["xhttpExtraParams"],separators=(",",":")))' "$STATE_DIR/host-settings.json")

if [[ "$CF_REFRESH" == 1 ]]; then
  systemctl daemon-reload
  systemctl enable --now krasnaya-cf-refresh.timer >/dev/null
else
  systemctl disable --now krasnaya-cf-refresh.timer >/dev/null 2>&1 || true
fi
ROLLBACK=0

printf '\n\033[1;32m✔ %s ready\033[0m\n\n' "$DOMAIN"
printf 'CDN path:       %s\n' "$XHTTP_PATH"
printf 'CDN+WARP path:  %s\n\n' "$XHTTP_WARP_PATH"
printf 'Host settings (both hosts):\n'
printf '  Address / SNI / Host:  %s\n' "$DOMAIN"
printf '  Port 443 · TLS · ALPN h2 · Fingerprint chrome\n'
printf '  Inbounds: VLESS_XHTTP_CDN (CDN) · VLESS_XHTTP_CDN_WARP (CDN+WARP)\n'
printf '  XHTTP Extra: %s\n\n' "$EXTRA_JSON"
if [[ "$SITE_CODE" != 200 || "$ACL1" != 403 || "$ACL2" != 403 ]]; then
  warn "Self-check: site=$SITE_CODE /relay/=$ACL1 /cache/=$ACL2 (expected 200/403/403)"
fi
printf 'Saved: %s/host-settings.txt   Backup: %s\n' "$STATE_DIR" "$BACKUP_DIR"
