#!/bin/bash
# Removes Saywell. Asks before deleting your dictation history and models.
set -uo pipefail
pkill -x Saywell 2>/dev/null || true
for d in /Applications "$HOME/Applications"; do
  [ -d "$d/Saywell.app" ] && rm -rf "$d/Saywell.app" && echo "Removed $d/Saywell.app"
done
tccutil reset All com.gourav.saywell >/dev/null 2>&1 && echo "Reset Saywell's privacy permissions"
read -r -p "Also delete dictation history, training samples and downloaded models? [y/N] " answer
if [[ "$answer" =~ ^[Yy]$ ]]; then
  rm -rf "$HOME/Library/Application Support/Saywell" "$HOME/Library/Logs/Saywell.log" "$HOME/Library/Logs/Saywell-train.log"
  echo "Deleted Saywell data. (Models in ~/.cache/huggingface are shared with other tools and were left alone.)"
fi
echo "Saywell is uninstalled."
