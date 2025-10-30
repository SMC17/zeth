#!/bin/bash
# Repository cleanup script - moves files to organized structure

set -e

# Move week files
mv WEEK1_*.md docs/internal/week1/ 2>/dev/null || true
mv WEEK2_*.md docs/internal/week2/ 2>/dev/null || true
mv WEEK3_*.md docs/internal/week3/ 2>/dev/null || true

# Move validation docs
mv validation/*.md docs/validation/ 2>/dev/null || true

# Move internal tracking
mv ACHIEVEMENTS.md docs/internal/ 2>/dev/null || true
mv CURRENT_STATUS.md docs/internal/ 2>/dev/null || true
mv EXECUTIVE_SUMMARY.md docs/internal/ 2>/dev/null || true
mv FINAL_STATUS.md docs/internal/ 2>/dev/null || true
mv INITIAL_ISSUES.md docs/internal/ 2>/dev/null || true
mv PROGRESS_UPDATE.md docs/internal/ 2>/dev/null || true
mv REALITY_CHECK.md docs/internal/ 2>/dev/null || true
mv SESSION_SUMMARY.md docs/internal/ 2>/dev/null || true
mv SOCIAL_MEDIA.md docs/internal/ 2>/dev/null || true
mv STATUS.md docs/internal/ 2>/dev/null || true

# Move architecture docs
mv PROJECT_STATUS.md docs/architecture/ 2>/dev/null || true
mv TECHNICAL_EXCELLENCE.md docs/architecture/ 2>/dev/null || true
mv IMPLEMENTATION_STATUS.md docs/architecture/ 2>/dev/null || true
mv EVM_PARITY_STATUS.md docs/architecture/ 2>/dev/null || true
mv ARCHITECTURE.md docs/architecture/ 2>/dev/null || true

# Move validation docs
mv BUGS_FOUND.md docs/validation/ 2>/dev/null || true
mv KNOWN_ISSUES.md docs/validation/ 2>/dev/null || true

# Move community docs
mv ROADMAP.md docs/community/ 2>/dev/null || true
mv PROJECT_ROADMAP.md docs/community/ 2>/dev/null || true
mv CONTRIBUTORS.md docs/community/ 2>/dev/null || true

# Keep in root (will be updated)
# README.md - stay
# LICENSE - stay  
# CONTRIBUTING.md - stay (or move to docs/development/)

echo "Repository cleanup complete!"
