#!/usr/bin/env bash
#
# deploy-aisia-quadlets.sh
#
# Purpose:
#   - Discover Podman Quadlet (.container) files in this repo
#   - Let the user select which "tools" to install as services
#   - Install them into the user's Quadlet directory
#   - Reload and enable the corresponding systemd --user services
#   - Optionally enable linger so services persist after logout/reboot
#
# Assumptions:
#   - You have already cloned the repo locally.
#   - Quadlet files live under: self-contained/quadlets/*.container
#     (You can change QUADLET_SRC_DIR below if your layout changes.)
#   - You're using rootless Podman + systemd --user.
#
# Notes for future expansion:
#   - As you add new tools, just drop new *.container files into
#     self-contained/quadlets/ and re-run this script.
#   - If you later introduce per-tool metadata (e.g. YAML/JSON),
#     you can extend the "install_tool" function to read it.
#

set -euo pipefail

########################################
# CONFIGURABLE DEFAULTS
########################################

# Root of the AISIA repo. By default, use the directory where this script lives.
# You can override via: REPO_DIR=/path/to/repo ./deploy-aisia-quadlets.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$SCRIPT_DIR}"

# Where we expect the Quadlet (.container) files to live inside the repo.
# Adjust this if you move things around in the repo.
QUADLET_SRC_DIR="${QUADLET_SRC_DIR:-$REPO_DIR/self-contained/quadlets}"

# Destination for *user* Quadlets. This is where Podman’s systemd generator
# will look for user-level .container files.
QUADLET_DEST_DIR="${QUADLET_DEST_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"

# Install mode: "copy" or "symlink"
# - copy:   makes a standalone copy of the quadlet file in your config dir.
# - symlink:keeps a symlink pointing back into the git repo (easier updates).
INSTALL_MODE="${INSTALL_MODE:-copy}"

########################################
# UTILITY FUNCTIONS
########################################

# Print a simple heading for readability.
header() {
  echo
  echo "============================================================"
  echo "$1"
  echo "============================================================"
}

# Print an error message and exit.
die() {
  echo "ERROR: $*" >&2
  exit 1
}

########################################
# ENVIRONMENT CHECKS
########################################

header "Environment checks"

# Confirm we can find the source quadlet directory.
if [[ ! -d "$QUADLET_SRC_DIR" ]]; then
  die "Quadlet source directory does not exist: $QUADLET_SRC_DIR
Please check QUADLET_SRC_DIR or your repo layout."
fi

echo "Repo directory:        $REPO_DIR"
echo "Quadlet source dir:    $QUADLET_SRC_DIR"
echo "Quadlet dest dir:      $QUADLET_DEST_DIR"
echo "Install mode:          $INSTALL_MODE"

# Ensure destination directory for user quadlets exists.
mkdir -p "$QUADLET_DEST_DIR"

########################################
# DISCOVER AVAILABLE QUADLETS
########################################

header "Discovering available tools (quadlets)"

# Find all *.container files in the source directory.
# This builds two arrays:
#   QUADLET_FILES: absolute paths to .container files
#   TOOL_NAMES:    base names without extension (used as unit names)
mapfile -t QUADLET_FILES < <(find "$QUADLET_SRC_DIR" -maxdepth 1 -type f -name '*.container' | sort || true)

if [[ ${#QUADLET_FILES[@]} -eq 0 ]]; then
  die "No .container files found in $QUADLET_SRC_DIR"
fi

TOOL_NAMES=()

for f in "${QUADLET_FILES[@]}"; do
  # Extract the filename (e.g. comfyui-gpu.container)
  fname="$(basename "$f")"
  # Strip the .container extension to get a logical "tool name"
  tool="${fname%.container}"
  TOOL_NAMES+=("$tool")
done

echo "Discovered tools:"
for i in "${!TOOL_NAMES[@]}"; do
  printf "  %2d) %-25s (%s)\n" "$((i+1))" "${TOOL_NAMES[$i]}" "$(basename "${QUADLET_FILES[$i]}")"
done

########################################
# INTERACTIVE SELECTION
########################################

header "Select tools to deploy"

echo "Enter one or more numbers separated by spaces to deploy specific tools."
echo "  - Example: 1 3 5"
echo "  - Or enter 'a' to deploy ALL tools."
echo "  - Or 'q' to quit without changes."
echo

read -rp "Selection: " selection

# Normalize selection to lowercase once
selection_trimmed="$(echo "$selection" | xargs || true)"

if [[ -z "$selection_trimmed" ]]; then
  die "No selection provided. Exiting."
fi

if [[ "$selection_trimmed" == "q" || "$selection_trimmed" == "Q" ]]; then
  echo "Quitting without changes."
  exit 0
fi

# Determine which indices to use
SELECTED_INDICES=()

if [[ "$selection_trimmed" == "a" || "$selection_trimmed" == "A" ]]; then
  # Add all indices if user chose "all"
  for i in "${!TOOL_NAMES[@]}"; do
    SELECTED_INDICES+=("$i")
  done
else
  # Parse each token as a number and map to zero-based indices
  for token in $selection_trimmed; do
    if ! [[ "$token" =~ ^[0-9]+$ ]]; then
      die "Invalid token in selection: '$token' (must be numbers, 'a', or 'q')"
    fi
    idx=$((token-1))  # convert 1-based menu to 0-based array index
    if (( idx < 0 || idx >= ${#TOOL_NAMES[@]} )); then
      die "Selection '$token' is out of range."
    fi
    SELECTED_INDICES+=("$idx")
  done
fi

# Remove potential duplicates while preserving order
UNIQUE_INDICES=()
seen=""
for idx in "${SELECTED_INDICES[@]}"; do
  case " $seen " in
    *" $idx "*) : ;; # already seen
    *) UNIQUE_INDICES+=("$idx"); seen+=" $idx" ;;
  esac
done

echo
echo "You chose to deploy:"
for idx in "${UNIQUE_INDICES[@]}"; do
  echo "  - ${TOOL_NAMES[$idx]}"
done

########################################
# OPTIONAL: ENABLE LINGER FOR USER SERVICES
########################################

header "Linger (keep user services running after logout)"

# Linger allows systemd --user services to keep running even when you are
# not logged in, which is usually what you want for long-running AI services.
#
# We try to detect if linger is already enabled. If not, we offer to enable it.
LINGER_STATUS="$(loginctl show-user "$USER" 2>/dev/null | awk -F= '/^Linger=/{print $2}' || echo "unknown")"

case "$LINGER_STATUS" in
  yes)
    echo "Linger is already enabled for user '$USER'."
    ;;
  no)
    echo "Linger is currently DISABLED for user '$USER'."
    echo "This means your --user services will stop when you log out."
    echo
    read -rp "Enable linger for '$USER' now? (y/N): " ans
    ans="${ans:-n}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      echo "Enabling linger (requires sudo)..."
      if sudo loginctl enable-linger "$USER"; then
        echo "Linger enabled."
      else
        echo "WARNING: Failed to enable linger. You may need to run:"
        echo "  sudo loginctl enable-linger $USER"
      fi
    else
      echo "Leaving linger disabled. Services will stop when you log out."
    fi
    ;;
  *)
    echo "Could not determine linger status for '$USER' (status: $LINGER_STATUS)."
    echo "If you want services to run across logouts, run:"
    echo "  sudo loginctl enable-linger $USER"
    ;;
esac

########################################
# INSTALL FUNCTION
########################################

install_tool() {
  local src_file="$1"  # full path to .container in repo
  local tool_name="$2" # base name without extension

  # Destination path for this quadlet file
  local dest_file="$QUADLET_DEST_DIR/${tool_name}.container"

  echo
  echo "------------------------------------------------------------"
  echo "Installing tool: $tool_name"
  echo "  Source: $src_file"
  echo "  Dest:   $dest_file"
  echo "------------------------------------------------------------"

  case "$INSTALL_MODE" in
    copy)
      # Copy the quadlet file content into the user config dir.
      cp -f "$src_file" "$dest_file"
      ;;
    symlink)
      # Create/overwrite a symlink to the quadlet file in the repo.
      ln -sf "$src_file" "$dest_file"
      ;;
    *)
      die "Unknown INSTALL_MODE='$INSTALL_MODE'. Use 'copy' or 'symlink'."
      ;;
  esac

  # For SELinux-enabled systems (Fedora/RHEL), you may want to ensure the
  # quadlet directory has the correct context. We do NOT modify SELinux here,
  # but you can run the below manually if needed:
  #
  #   sudo chcon -Rt container_file_t "$QUADLET_DEST_DIR"
  #
  # This is intentionally a comment-only hint, to keep this script conservative.
}

########################################
# INSTALL SELECTED TOOLS
########################################

header "Installing selected tools"

UNIT_NAMES=()

for idx in "${UNIQUE_INDICES[@]}"; do
  src="${QUADLET_FILES[$idx]}"
  tool="${TOOL_NAMES[$idx]}"

  install_tool "$src" "$tool"

  # For a quadlet file "foo.container", systemd will normally generate a
  # systemd unit "foo.service" (assuming the .container file has correct [Install]).
  UNIT_NAMES+=("${tool}.service")
done

########################################
# RELOAD SYSTEMD-USER + ENABLE SERVICES
########################################

header "Reloading systemd --user and enabling services"

echo "Reloading quadlets via systemd --user daemon-reload..."
systemctl --user daemon-reload

echo
echo "Enabling and starting services:"
for unit in "${UNIT_NAMES[@]}"; do
  echo "  systemctl --user enable --now $unit"
  systemctl --user enable --now "$unit" || {
    echo "WARNING: Failed to enable/start $unit. Check its unit file and logs:"
    echo "  journalctl --user -u $unit -n 100 --no-pager"
  }
done

########################################
# SUMMARY
########################################

header "Done"

echo "Installed quadlets into: $QUADLET_DEST_DIR"
echo "The following services were processed:"
for unit in "${UNIT_NAMES[@]}"; do
  echo "  - $unit"
done

echo
echo "Tips:"
echo "  - Check status:   systemctl --user status <service>.service"
echo "  - View logs:      journalctl --user -u <service>.service -n 100 --no-pager"
echo "  - To add a new tool:"
echo "        1) Drop a new *.container file into:"
echo "             $QUADLET_SRC_DIR"
echo "        2) Re-run this script and select it."
echo
echo "If you change quadlet definitions in the repo (and use INSTALL_MODE=symlink),"
echo "a 'systemctl --user daemon-reload' is usually enough to pick up changes."
