#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
WP_DIR="/var/www/html"
WEB_GROUP="www-data"
RESERVED_USERS=("root" "ubuntu" "www-data")

need_root() {
  [[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
}

prompt_new_user() {
  echo "=============================="
  echo " Webmin + WordPress Setup (NO ROOT LOGIN)"
  echo "=============================="
  echo

  while true; do
    read -rp "Enter NEW username to create: " NEW_USER
    [[ -n "${NEW_USER:-}" ]] || { echo "Username cannot be empty."; continue; }

    for u in "${RESERVED_USERS[@]}"; do
      if [[ "$NEW_USER" == "$u" ]]; then
        echo "Username '$NEW_USER' is reserved. Choose a different username."
        NEW_USER=""
        break
      fi
    done
    [[ -n "${NEW_USER:-}" ]] || continue

    if id "$NEW_USER" &>/dev/null; then
      echo "User '$NEW_USER' already exists. Please choose a different username."
      continue
    fi
    break
  done

  while true; do
    read -rsp "Enter password for $NEW_USER: " PASS1; echo
    read -rsp "Confirm password: " PASS2; echo
    [[ -n "${PASS1:-}" && "$PASS1" == "$PASS2" ]] && break
    echo "Passwords do not match or are empty. Try again."
  done
  echo
}

install_deps() {
  echo "==> Installing dependencies..."
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg apt-transport-https software-properties-common acl
}

install_webmin_official_repo() {
  echo "==> Installing Webmin from OFFICIAL repository..."
  curl -fsSL -o /tmp/webmin-setup-repo.sh \
    https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh

  bash /tmp/webmin-setup-repo.sh
  apt-get update -y
  apt-get install -y webmin

  systemctl enable --now webmin
  systemctl restart webmin
}

create_linux_user_only() {
  echo "==> Creating Linux user '$NEW_USER'..."
  useradd -m -s /bin/bash "$NEW_USER"
  echo "$NEW_USER:$PASS1" | chpasswd

  echo "==> Adding '$NEW_USER' to group '$WEB_GROUP'..."
  usermod -aG "$WEB_GROUP" "$NEW_USER"
}

fix_wp_permissions() {
  echo "==> Checking WordPress directory: $WP_DIR"
  [[ -d "$WP_DIR" ]] || { echo "ERROR: $WP_DIR not found. Set WP_DIR correctly."; exit 1; }

  echo "==> Applying shared permissions for WordPress files..."

  chown -R "$WEB_GROUP:$WEB_GROUP" "$WP_DIR"

  find "$WP_DIR" -type d -exec chmod 2775 {} \;
  find "$WP_DIR" -type f -exec chmod 0664 {} \;

  setfacl -R -m "u:${NEW_USER}:rwX" -m "g:${WEB_GROUP}:rwX" "$WP_DIR"
  setfacl -R -d -m "u:${NEW_USER}:rwX" -m "g:${WEB_GROUP}:rwX" "$WP_DIR"
}

create_webmin_user_admin_no_root_login() {
  echo "==> Creating Webmin user '$NEW_USER' (admin), disabling root login..."

  local miniserv_users="/etc/webmin/miniserv.users"
  local webmin_acl="/etc/webmin/webmin.acl"
  local miniserv_conf="/etc/webmin/miniserv.conf"
  local changepass="/usr/share/webmin/changepass.pl"

  [[ -f "$miniserv_users" ]] || { echo "ERROR: $miniserv_users not found"; exit 1; }
  [[ -f "$webmin_acl" ]] || { echo "ERROR: $webmin_acl not found"; exit 1; }
  [[ -f "$miniserv_conf" ]] || { echo "ERROR: $miniserv_conf not found"; exit 1; }
  [[ -x "$changepass" ]] || { echo "ERROR: $changepass not found/executable"; exit 1; }

  # Ensure entry exists in miniserv.users; password set by changepass.pl
  if ! grep -q "^${NEW_USER}:" "$miniserv_users"; then
    echo "${NEW_USER}:x:0" >> "$miniserv_users"
  fi

  "$changepass" /etc/webmin "$NEW_USER" "$PASS1" >/dev/null

  # Copy root's Webmin ACL privileges to NEW_USER
  local root_line
  root_line="$(grep -m1 '^root:' "$webmin_acl" || true)"
  [[ -n "$root_line" ]] || { echo "ERROR: Could not find root ACL in $webmin_acl"; exit 1; }

  sed -i "/^${NEW_USER}:/d" "$webmin_acl"
  echo "${root_line/root:/${NEW_USER}:}" >> "$webmin_acl"

  # Disable root Webmin login:
  # 1) Restrict allowed Webmin logins to ONLY this user
  if grep -q '^allowusers=' "$miniserv_conf"; then
    sed -i "s/^allowusers=.*/allowusers=${NEW_USER}/" "$miniserv_conf"
  else
    echo "allowusers=${NEW_USER}" >> "$miniserv_conf"
  fi

  # 2) Remove root from miniserv.users (prevents root auth even if allowusers changes later)
  sed -i '/^root:/d' "$miniserv_users"
  # (Optional) also remove root ACL line (not required if root can't login)
  # sed -i '/^root:/d' "$webmin_acl"

  systemctl restart webmin
}

print_finish() {
  echo
  echo ":white_check_mark: Done! (Root Webmin login disabled)"
  echo "Webmin URL: https://<EC2_PUBLIC_IP>:10000"
  echo "Login: $NEW_USER"
  echo
  echo "AWS Security Group must allow TCP 10000 from your IP."
  echo "SSH: log out/in once so group membership applies."
}

main() {
  need_root
  prompt_new_user
  install_deps
  install_webmin_official_repo
  create_linux_user_only
  fix_wp_permissions
  create_webmin_user_admin_no_root_login
  print_finish
}

main "$@"
