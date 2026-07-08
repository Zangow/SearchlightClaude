#!/usr/bin/env bash
#
# sl-move-issue-column.sh — move an EXISTING GitHub issue's card into a named
# column (a Status single-select option) of the "Searchlight Integration
# Service" project (Zangow user project).
#
# Looks up the issue's card on the board and, if the issue isn't on the board
# yet, adds it first. Idempotent: moving a card already in the target column is
# a no-op.
#
# Usage:
#   sl-move-issue-column.sh <owner/repo> <issue-number> "<column-name>"
# Example:
#   sl-move-issue-column.sh Zangow/IntegrationService 12 "In progress"
#
# Columns as of 2026-07: Backlog | Ready | In progress | In review | Done
#
# Prints "<issue-url> -> <column-name>" on success. Requires the `read:project`
# and `project` gh scopes (gh auth refresh -s read:project,project).
#
# IDs are resolved BY NAME at runtime, so renaming the project, the Status
# field, or a column is fine as long as the names below still exist. To inspect
# the available column names by hand:
#   gh project field-list <n> --owner Zangow --format json \
#     --jq '.fields[] | select(.name=="Status") | .options[].name'
set -euo pipefail

OWNER="Zangow"
PROJECT_NAME="Searchlight Integration Service"
STATUS_FIELD_NAME="Status"

REPO="${1:?owner/repo required}"
NUM="${2:?issue number required}"
COLUMN_NAME="${3:?column name required}"

URL="https://github.com/$REPO/issues/$NUM"

# Resolve project number + node id, the Status field id, and the target column's
# option id — all by name.
# `|| true` so a failed/empty lookup reaches the friendly :?-guard instead of tripping set -e.
read -r PNUM PID < <(gh project list --owner "$OWNER" --format json \
  --jq ".projects[] | select(.title==\"$PROJECT_NAME\") | \"\(.number) \(.id)\"") || true
: "${PNUM:?could not find project \"$PROJECT_NAME\" under $OWNER}"
FIELD_ID=$(gh project field-list "$PNUM" --owner "$OWNER" --format json \
  --jq ".fields[] | select(.name==\"$STATUS_FIELD_NAME\") | .id")
: "${FIELD_ID:?could not find the $STATUS_FIELD_NAME field on the project}"
OPT_ID=$(gh project field-list "$PNUM" --owner "$OWNER" --format json \
  --jq ".fields[] | select(.name==\"$STATUS_FIELD_NAME\") | .options[] | select(.name==\"$COLUMN_NAME\") | .id")
: "${OPT_ID:?could not find column \"$COLUMN_NAME\" in the $STATUS_FIELD_NAME field}"

# Find the issue's existing card by URL; add it to the board if it isn't there.
# The select() streams every match, so wrap in [..] | first to take one id even
# if the board somehow carries duplicate cards for the same URL.
ITEM_ID=$(gh project item-list "$PNUM" --owner "$OWNER" --format json --limit 5000 \
  --jq "[.items[] | select(.content.url==\"$URL\") | .id] | first // empty")
if [ -z "$ITEM_ID" ]; then
  ITEM_ID=$(gh project item-add "$PNUM" --owner "$OWNER" --url "$URL" --format json --jq '.id')
fi
: "${ITEM_ID:?could not resolve a project item for $URL}"

gh project item-edit --id "$ITEM_ID" --project-id "$PID" \
  --field-id "$FIELD_ID" --single-select-option-id "$OPT_ID" >/dev/null

echo "$URL -> $COLUMN_NAME"
