#!/usr/bin/env bash
set -euo pipefail

# Fleet-wide CI/CD workflow convention rollout.
# Renames publish-* → cd-*, ci-release → ci-version-bump.
# Reformats ci.yml: alphabetical job ordering, reference comment,
# no banners, standardized inputs.
#
# Usage: fleet-cicd-rename.sh <repo-name|all>

GITHUB_BASE="/Users/pmoore/dev/github"
GITHUB_ORG="vergil-project"
BRANCH="chore/383-cicd-workflow-convention"
SA_TAG="v1.5"  # Update to actual release tag

REPOS=(
  vergil-tooling-docker
  vergil-tooling-plugin
  mq-rest-admin-python
  mq-rest-admin-go
  mq-rest-admin-ruby
  mq-rest-admin-rust
  mq-rest-admin-common
  mq-rest-admin-dev-environment
  ai-research-methodology
)

rename_repo() {
  local repo="$1"
  local repo_path="${GITHUB_BASE}/${repo}"

  if [ ! -d "$repo_path" ]; then
    echo "SKIP: $repo — directory not found at $repo_path"
    return
  fi

  echo "=== Processing $repo ==="
  cd "$repo_path"

  git checkout develop
  git pull
  git checkout -b "$BRANCH" 2>/dev/null || git checkout "$BRANCH"

  local wf=".github/workflows"

  # --- CI workflow: rewrite with formatting convention ---
  if [ -f "$wf/ci.yml" ]; then
    if grep -q "ci-release\.yml" "$wf/ci.yml"; then
      sed -i.bak \
        -e 's|ci-release\.yml|ci-version-bump.yml|g' \
        "$wf/ci.yml"
      rm -f "$wf/ci.yml.bak"
    fi

    # Rename job key: "  release:" -> "  version:"
    if grep -q "^  release:" "$wf/ci.yml"; then
      sed -i.bak \
        -e 's/^  release:$/  version:/' \
        "$wf/ci.yml"
      rm -f "$wf/ci.yml.bak"
    fi

    # Remove banner comments
    sed -i.bak \
      -e '/^  # ---/d' \
      -e '/^  # ====/d' \
      "$wf/ci.yml"
    rm -f "$wf/ci.yml.bak"

    # Add reference comment if not present
    if ! grep -q "README.md" "$wf/ci.yml"; then
      sed -i.bak \
        "1i\\
# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md" \
        "$wf/ci.yml"
      rm -f "$wf/ci.yml.bak"
    fi

    # Rename language-prefixed version inputs to 'versions'
    sed -i.bak \
      -e 's/go-versions:/versions:/' \
      -e 's/ruby-versions:/versions:/' \
      -e 's/rust-versions:/versions:/' \
      -e 's/python-versions:/versions:/' \
      "$wf/ci.yml"
    rm -f "$wf/ci.yml.bak"

    # Remove yamllint pragmas
    sed -i.bak \
      -e '/# yamllint disable-line/d' \
      "$wf/ci.yml"
    rm -f "$wf/ci.yml.bak"

    echo "  Updated ci.yml"
  fi

  # --- Merge publish callers into cd.yml ---
  local has_release=false
  local has_docs=false

  if [ -f "$wf/publish-release.yml" ]; then
    has_release=true
  fi

  if [ -f "$wf/publish-docs.yml" ]; then
    has_docs=true
  fi

  if $has_release || $has_docs; then
    {
      echo "# https://github.com/vergil-project/vergil-actions/blob/develop/.github/workflows/README.md"
      echo "name: CD"
      echo ""
      echo "on:"
      echo "  push:"
      if $has_docs; then
        echo "    branches: [develop, main]"
      else
        echo "    branches: [main]"
      fi
      echo "  workflow_dispatch:"

      if $has_release; then
        echo ""
        echo "permissions:"
        echo "  attestations: write"
        echo "  contents: write"
        echo "  id-token: write"
        echo "  pull-requests: write"
      fi

      echo ""
      echo "jobs:"

      if $has_docs; then
        echo "  docs:"
        echo "    uses: ${GITHUB_ORG}/vergil-actions/.github/workflows/cd-docs.yml@${SA_TAG}"
        echo "    permissions:"
        echo "      contents: write"
      fi

      if $has_release; then
        if $has_docs; then
          echo ""
        fi
        echo "  release:"
        if $has_docs; then
          echo "    if: github.ref == 'refs/heads/main'"
        fi
        echo "    uses: ${GITHUB_ORG}/vergil-actions/.github/workflows/cd-release.yml@${SA_TAG}"

        # Extract the 'with:' block from publish-release.yml
        local with_block
        with_block=$(sed -n '/^    with:/,/^    [a-z]/{ /^    with:/p; /^      /p; }' "$wf/publish-release.yml" 2>/dev/null || true)
        if [ -n "$with_block" ]; then
          echo "$with_block"
        fi

        echo "    secrets: inherit"
      fi
    } > "$wf/cd.yml"

    $has_release && git rm "$wf/publish-release.yml"
    $has_docs && git rm "$wf/publish-docs.yml"
    git add "$wf/cd.yml"

    echo "  Created cd.yml, removed old publish files"
  fi

  git add -A
  if git diff --cached --quiet; then
    echo "  No changes — skipping"
    git checkout develop
    return
  fi

  vrg-commit --type feat --scope ci \
    --message "adopt CI/CD workflow convention (#383)" \
    --agent claude

  git push -u origin "$BRANCH"

  vrg-submit-pr \
    --issue "vergil-project/vergil-actions#383" \
    --linkage Ref \
    --title "feat(ci): adopt CI/CD workflow convention (#383)" \
    --summary "Rename ci-release ref to ci-version-bump, merge publish workflows into cd.yml, add reference comment, remove banners"

  echo "  PR created for $repo"
}

# --- Main ---
target="${1:-}"

if [ -z "$target" ]; then
  echo "Usage: $0 <repo-name|all>"
  exit 1
fi

if [ "$target" = "all" ]; then
  for repo in "${REPOS[@]}"; do
    rename_repo "$repo"
  done
else
  rename_repo "$target"
fi
