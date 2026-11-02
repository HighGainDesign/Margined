#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
VERSION="${1:?Usage: bash script/package-skill.sh VERSION [COMMIT_OR_TAG]}"
SOURCE_REF="${2:-HEAD}"
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || { echo 'Invalid skill package version.' >&2; exit 1; }
COMMIT=$(git rev-parse --verify --end-of-options "$SOURCE_REF^{commit}")
SKILL_PATH='skills/margined-markdown'
for REQUIRED in SKILL.md LICENSE agents/openai.yaml references/discussions.md references/maintenance.md assets/review-example.md; do
  git cat-file -e "$COMMIT:$SKILL_PATH/$REQUIRED" || { echo "Missing committed skill file: $REQUIRED" >&2; exit 1; }
done
mkdir -p dist
ARCHIVE="Margined-Markdown-Skill-$VERSION.zip"
git archive --format=zip --prefix=margined-markdown/ --output="dist/$ARCHIVE" "$COMMIT:$SKILL_PATH"
(cd dist; shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Ready: $ROOT_DIR/dist/$ARCHIVE"
