#!/bin/bash
set -euo pipefail

# Configuration
OLD_NAME_LOWER="hedging"
OLD_NAME_CAMEL="Hedging"
OLD_ATOM=":hedging"
NEW_NAME_LOWER="crucible_hedging"
NEW_NAME_CAMEL="CrucibleHedging"
NEW_ATOM=":crucible_hedging"

echo "════════════════════════════════════════════════════════════════"
echo "  EXECUTING: ${OLD_NAME_CAMEL} → ${NEW_NAME_CAMEL}"
echo "════════════════════════════════════════════════════════════════"
echo

# 1. Clean build artifacts
echo "[1/15] Cleaning build artifacts..."
rm -rf _build deps *.tar ${OLD_NAME_LOWER}-*/
echo "  ✓ Done"
echo

# 2. Update .gitignore
echo "[2/15] Updating .gitignore..."
grep -q '^\*.tar$' .gitignore 2>/dev/null || echo '*.tar' >> .gitignore
grep -q "^${OLD_NAME_LOWER}-" .gitignore 2>/dev/null || echo "${OLD_NAME_LOWER}-*/" >> .gitignore
grep -q "^${NEW_NAME_LOWER}-" .gitignore 2>/dev/null || echo "${NEW_NAME_LOWER}-*/" >> .gitignore
echo "  ✓ Done"
echo

# 3. Rename directories
echo "[3/15] Renaming directories..."
[ -d "lib/${OLD_NAME_LOWER}" ] && mv "lib/${OLD_NAME_LOWER}" "lib/${NEW_NAME_LOWER}" && echo "  ✓ lib/${OLD_NAME_LOWER}/ → lib/${NEW_NAME_LOWER}/"
[ -d "test/${OLD_NAME_LOWER}" ] && mv "test/${OLD_NAME_LOWER}" "test/${NEW_NAME_LOWER}" && echo "  ✓ test/${OLD_NAME_LOWER}/ → test/${NEW_NAME_LOWER}/"
echo

# 4. Update module definitions (with submodules)
echo "[4/15] Updating module definitions (submodules)..."
find . -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.md' \) ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/defmodule ${OLD_NAME_CAMEL}\./defmodule ${NEW_NAME_CAMEL}./g" {} +
echo "  ✓ Done"
echo

# 5. Update top-level module definition
echo "[5/15] Updating top-level module..."
find . -type f \( -name '*.ex' -o -name '*.exs' \) ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/defmodule ${OLD_NAME_CAMEL} do/defmodule ${NEW_NAME_CAMEL} do/g" {} +
echo "  ✓ Done"
echo

# 6. Update alias statements
echo "[6/15] Updating alias statements..."
find . -type f \( -name '*.ex' -o -name '*.exs' \) ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/alias ${OLD_NAME_CAMEL}$/alias ${NEW_NAME_CAMEL}/g" {} +
find . -type f \( -name '*.ex' -o -name '*.exs' \) ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/alias ${OLD_NAME_CAMEL},/alias ${NEW_NAME_CAMEL},/g" {} +
find . -type f \( -name '*.ex' -o -name '*.exs' \) ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/alias ${OLD_NAME_CAMEL}\./alias ${NEW_NAME_CAMEL}./g" {} +
echo "  ✓ Done"
echo

# 7. Update module usage
echo "[7/15] Updating module usage..."
find . -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.md' \) ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/${OLD_NAME_CAMEL}\./${NEW_NAME_CAMEL}./g" {} +
echo "  ✓ Done"
echo

# 8. Update prose/titles
echo "[8/15] Updating prose and titles..."
find . -type f -name '*.md' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/# ${OLD_NAME_CAMEL} -/# ${NEW_NAME_CAMEL} -/g" {} +
find . -type f -name '*.md' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/^${OLD_NAME_CAMEL} provides/${NEW_NAME_CAMEL} provides/g" {} +
echo "  ✓ Done"
echo

# 9. Update app atoms
echo "[9/15] Updating app atoms..."
find . -type f \( -name '*.ex' -o -name '*.exs' \) ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/${OLD_ATOM}/${NEW_ATOM}/g" {} +
echo "  ✓ Done"
echo

# 10. Update strings
echo "[10/15] Updating string references..."
find . -type f -name 'mix.exs' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/\"${OLD_NAME_LOWER}\"/\"${NEW_NAME_LOWER}\"/g" {} +
find . -type f -name 'README.md' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/{:${OLD_NAME_LOWER},/{:${NEW_NAME_LOWER},/g" {} +
echo "  ✓ Done"
echo

# 11. Update package name
echo "[11/15] Updating package name..."
find . -type f -name 'mix.exs' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/name: \"${OLD_NAME_LOWER}\"/name: \"${NEW_NAME_LOWER}\"/g" {} +
echo "  ✓ Done"
echo

# 12. Update app field
echo "[12/15] Updating app field..."
find . -type f -name 'mix.exs' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/app: ${OLD_ATOM}/app: ${NEW_ATOM}/g" {} +
echo "  ✓ Done"
echo

# 13. Update main doc field
echo "[13/15] Updating main field..."
find . -type f -name 'mix.exs' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s/main: \"${OLD_NAME_CAMEL}\"/main: \"${NEW_NAME_CAMEL}\"/g" {} +
echo "  ✓ Done"
echo

# 14. Remove umbrella references
echo "[14/15] Removing umbrella references..."
find . -type f -name 'README.md' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "/sparse:.*apps\/${OLD_NAME_LOWER}/d" {} +
find . -type f -name 'README.md' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "/cd apps\/${OLD_NAME_LOWER}/d" {} +
find . -type f -name 'README.md' ! -path './.git/*' ! -path "./${OLD_NAME_LOWER}-*/*" -exec sed -i "s|lib/${OLD_NAME_LOWER}/|lib/${NEW_NAME_LOWER}/|g" {} +
echo "  ✓ Done"
echo

# 15. Verify
echo "[15/15] Verification..."
REMAINING_ATOM=$(grep -r "${OLD_ATOM}[^a-z_]" --include="*.ex" --include="*.exs" . 2>/dev/null | grep -v ".git" | wc -l || echo "0")
REMAINING_MODULE=$(grep -r "defmodule ${OLD_NAME_CAMEL}" --include="*.ex" . 2>/dev/null | grep -v ".git" | wc -l || echo "0")
echo "  Remaining ${OLD_ATOM}: $REMAINING_ATOM"
echo "  Remaining defmodule ${OLD_NAME_CAMEL}: $REMAINING_MODULE"
echo

echo "════════════════════════════════════════════════════════════════"
echo "  ✓ RENAME COMPLETE"
echo "════════════════════════════════════════════════════════════════"
echo
echo "Next steps:"
echo "  1. git diff"
echo "  2. Update source_url in mix.exs to: https://github.com/North-Shore-AI/${NEW_NAME_LOWER}"
echo "  3. mix deps.get && mix compile && mix test"
