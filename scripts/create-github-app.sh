#!/usr/bin/env bash
# Create a GitHub App in an organization from a manifest (GitHub's manifest
# flow), so the App needs one click in the browser instead of a settings form.
#
# The script serves a small form on localhost that posts the manifest to
# GitHub, catches GitHub's redirect back to localhost, and converts the code
# it carries into the App's credentials. It saves the private key with mode
# 600 to the path you give and never prints it. It prints the App id, the
# client id, and the install link. The webhook secret and client secret are
# discarded: webhooks are off and nothing uses OAuth.
#
# Presets:
#   bootstrap  The App the bootstrap's github provider authenticates as
#              (github_app_id). One private App per MSP, installable only on
#              the MSP's own organization.
#   checks     The App the engine writes its check runs as
#              (checks_app_client_id). One per organization, installable only
#              on that organization.
#
# Needs curl, jq, and python3 for the localhost listener. Without python3 it
# opens the form as a file and asks you to paste the address GitHub redirects
# to.
#
# Usage:
#   scripts/create-github-app.sh -o <org> -p bootstrap -k ~/keys/bootstrap.pem
#   scripts/create-github-app.sh -o <org> -p checks -k ~/keys/checks.pem
set -euo pipefail

org=""
preset=""
key_file=""
name=""
port=8787

usage() {
  cat >&2 <<'EOF'
Create a GitHub App in an organization from a manifest.

Options:
  -o, --org ORG        Organization that owns the App. You must be an owner.
  -p, --preset NAME    bootstrap or checks.
  -k, --key-file PATH  Where to save the private key (mode 600). Must not exist.
  -n, --name NAME      App name, unique across GitHub, at most 34 characters.
                       Default: alz-bootstrap-<org> or tf-pr-ops-<org>.
      --port PORT      Localhost port for the redirect. Default 8787.
  -h, --help           Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--org) org="$2"; shift 2 ;;
    -p|--preset) preset="$2"; shift 2 ;;
    -k|--key-file) key_file="$2"; shift 2 ;;
    -n|--name) name="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$org" ] && [ -n "$preset" ] && [ -n "$key_file" ] || { usage; exit 2; }
for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required." >&2; exit 1; }
done

# Repository permissions use their API names; actions_variables is the
# repository Variables permission. Metadata read is implicit.
case "$preset" in
  bootstrap)
    name="${name:-alz-bootstrap-${org}}"
    # Installed only on the organization that owns it; nobody else needs to
    # find it.
    public=false
    # actions: the OIDC subject claim template. administration: the repository,
    # environments, ruleset, team access. contents: files written into the
    # repository. members: the approver team.
    permissions='{
      "actions": "write",
      "administration": "write",
      "contents": "write",
      "actions_variables": "write",
      "secrets": "write",
      "environments": "write",
      "members": "write"
    }'
    ;;
  checks)
    name="${name:-tf-pr-ops-${org}}"
    public=false
    permissions='{"checks": "write"}'
    ;;
  *) echo "Unknown preset: $preset (bootstrap or checks)." >&2; exit 2 ;;
esac

if [ "${#name}" -gt 34 ]; then
  echo "App name '$name' is longer than 34 characters; pass a shorter one with -n." >&2
  exit 2
fi
key_file="${key_file/#\~/$HOME}"
if [ -e "$key_file" ]; then
  echo "$key_file already exists; refusing to overwrite a private key." >&2
  exit 1
fi
mkdir -p "$(dirname "$key_file")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

state="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 32 || true)"
redirect_url="http://localhost:${port}/callback"

manifest="$(jq -n \
  --arg name "$name" \
  --arg url "https://github.com/${org}" \
  --arg redirect "$redirect_url" \
  --argjson public "$public" \
  --argjson permissions "$permissions" \
  '{
    name: $name,
    url: $url,
    hook_attributes: {url: $url, active: false},
    redirect_url: $redirect,
    public: $public,
    default_permissions: $permissions,
    default_events: [],
    request_oauth_on_install: false
  }')"

cat >"$work/form.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<title>Create GitHub App ${name}</title>
<form id="manifest" method="post" action="https://github.com/organizations/${org}/settings/apps/new?state=${state}">
  <input type="hidden" name="manifest" value="$(jq -rn --arg m "$manifest" '$m | @html')">
  <button type="submit">Create ${name} on GitHub</button>
</form>
<script>document.getElementById("manifest").submit();</script>
EOF

open_url() {
  if command -v open >/dev/null; then open "$1"
  elif command -v xdg-open >/dev/null; then xdg-open "$1" >/dev/null 2>&1
  else echo "Open this in a browser: $1"
  fi
}

echo "Creating '$name' in $org (preset $preset)."
echo "Your browser opens GitHub's create page. Check the name and click Create GitHub App."

code=""
if command -v python3 >/dev/null; then
  listener="$work/listener.py"
  cat >"$listener" <<'PY'
import http.server, sys, urllib.parse

form_path, state, port = sys.argv[1], sys.argv[2], int(sys.argv[3])

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(body.encode())

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/":
            with open(form_path) as f:
                self.reply(200, f.read())
            return
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/callback" and query.get("state", [""])[0] == state and query.get("code"):
            self.reply(200, "<p>App created. You can close this tab and return to the terminal.</p>")
            print(query["code"][0], flush=True)
            self.server.done = True
            return
        self.reply(400, "<p>Unexpected request.</p>")

class Server(http.server.HTTPServer):
    timeout = 900
    done = False

    def handle_timeout(self):
        sys.exit("Timed out waiting for GitHub's redirect.")

server = Server(("127.0.0.1", port), Handler)
while not server.done:
    server.handle_request()
PY
  python3 -I "$listener" "$work/form.html" "$state" "$port" >"$work/code" &
  listener_pid=$!
  sleep 1
  kill -0 "$listener_pid" 2>/dev/null || { echo "Could not listen on localhost:$port; pass another --port." >&2; exit 1; }
  open_url "http://localhost:${port}/"
  wait "$listener_pid"
  code="$(cat "$work/code")"
else
  open_url "file://$work/form.html"
  echo "GitHub then redirects to $redirect_url, which will not load."
  read -r -p "Paste the full address from the browser's address bar: " returned
  [[ "$returned" == *"state=${state}"* ]] || { echo "The state does not match; start again." >&2; exit 1; }
  code="$(sed -n -E 's/.*[?&]code=([^&]+).*/\1/p' <<<"$returned")"
fi
[ -n "$code" ] || { echo "No code received from GitHub." >&2; exit 1; }

# The code is single use and expires after an hour. The conversion needs no
# authentication.
umask 077
curl -fsS -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app-manifests/${code}/conversions" >"$work/app.json" || {
  echo "Converting the code failed. If GitHub created the App, generate a private key on its settings page instead." >&2
  exit 1
}

jq -r '.pem' "$work/app.json" >"$key_file"
chmod 600 "$key_file"

app_id="$(jq -r '.id' "$work/app.json")"
slug="$(jq -r '.slug' "$work/app.json")"
client_id="$(jq -r '.client_id' "$work/app.json")"

cat <<EOF

Created $slug in $org.
  App id:      $app_id
  Client id:   $client_id
  Private key: $key_file (mode 600)
  Settings:    https://github.com/organizations/${org}/settings/apps/${slug}

Install it: https://github.com/apps/${slug}/installations/new
EOF

case "$preset" in
  bootstrap)
    cat <<EOF
  Install on $org, the MSP's own organization. "Only
  select repositories" is enough: a repository the App creates joins the
  installation (an empty organization needs a placeholder repository
  selected). Then read the installation id:
    gh api orgs/<org>/installations --jq '.installations[] | select(.app_slug == "$slug") | .id'

Customer tfvars:
  github_app_id              = "$app_id"
  github_app_installation_id = "<installation id>"
  github_app_pem_file        = "$key_file"
EOF
    ;;
  checks)
    cat <<EOF
  Install on $org with "All repositories", so every customer repository the
  bootstrap creates is covered.

Customer tfvars:
  checks_app_client_id = "$client_id"
  checks_app_id        = $app_id
Before every plan or apply:
  export TF_VAR_checks_app_private_key="\$(cat $key_file)"
EOF
    ;;
esac
