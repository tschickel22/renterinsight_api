#!/bin/bash
# Phase 3 Backend Cleanup Script
# Removes console logs, TODOs, and development artifacts

echo "🧹 Phase 3: Backend Production Cleanup"
echo "======================================="
echo ""

cd /home/tschi/src/renterinsight_api

# Counter variables
BAK_FILES=0
CONSOLE_LINES=0
TODO_LINES=0

echo "📋 Step 1: Removing .bak files..."
echo "-----------------------------------"

# Find and count .bak files
BAK_COUNT=$(find app -type f -name "*.bak*" 2>/dev/null | wc -l)
if [ $BAK_COUNT -gt 0 ]; then
  echo "Found $BAK_COUNT .bak files"
  find app -type f -name "*.bak*" -delete 2>/dev/null
  echo "✅ Removed $BAK_COUNT .bak files"
  BAK_FILES=$BAK_COUNT
else
  echo "✅ No .bak files found"
fi

echo ""
echo "📋 Step 2: Scanning for console/debug output..."
echo "-----------------------------------"

# Search for puts, p, pp, print statements (Ruby debug output)
echo "Searching for debug output (puts, print, pp, p)..."

# Create report of files with debug statements
find app -type f -name "*.rb" -exec grep -l "\bputs\b\|\bprint\b\|\bpp\b\|\bp\s" {} \; > /tmp/debug_files.txt 2>/dev/null

if [ -s /tmp/debug_files.txt ]; then
  echo "⚠️  Files with debug output found:"
  cat /tmp/debug_files.txt | while read file; do
    count=$(grep -c "\bputs\b\|\bprint\b\|\bpp\b\|\bp\s" "$file" 2>/dev/null)
    echo "  - $file ($count occurrences)"
    CONSOLE_LINES=$((CONSOLE_LINES + count))
  done
  echo ""
  echo "Total debug statements: $CONSOLE_LINES"
  echo "⚠️  Manual review recommended for these files"
else
  echo "✅ No debug output found"
fi

echo ""
echo "📋 Step 3: Scanning for TODO/FIXME comments..."
echo "-----------------------------------"

# Search for TODO, FIXME, XXX, HACK comments
echo "Searching for TODO/FIXME/XXX/HACK comments..."

find app -type f -name "*.rb" -exec grep -l "TODO\|FIXME\|XXX\|HACK" {} \; > /tmp/todo_files.txt 2>/dev/null

if [ -s /tmp/todo_files.txt ]; then
  echo "⚠️  Files with TODO/FIXME comments found:"
  cat /tmp/todo_files.txt | while read file; do
    count=$(grep -c "TODO\|FIXME\|XXX\|HACK" "$file" 2>/dev/null)
    echo "  - $file ($count comments)"
    TODO_LINES=$((TODO_LINES + count))
  done
  echo ""
  echo "Total TODO comments: $TODO_LINES"
  echo "⚠️  Manual review recommended for these files"
else
  echo "✅ No TODO/FIXME comments found"
fi

echo ""
echo "📋 Step 4: Listing files with 'stub' or 'mock' in name..."
echo "-----------------------------------"

STUB_FILES=$(find app -type f -name "*stub*" -o -name "*mock*" 2>/dev/null | wc -l)
if [ $STUB_FILES -gt 0 ]; then
  echo "⚠️  Files with 'stub' or 'mock' in name:"
  find app -type f -name "*stub*" -o -name "*mock*" 2>/dev/null
else
  echo "✅ No stub/mock files found"
fi

echo ""
echo "======================================="
echo "📊 Phase 3 Cleanup Summary"
echo "======================================="
echo "✅ .bak files removed: $BAK_FILES"
echo "⚠️  Debug statements found: $CONSOLE_LINES"
echo "⚠️  TODO comments found: $TODO_LINES"
echo "⚠️  Stub/mock files: $STUB_FILES"
echo ""

if [ $CONSOLE_LINES -gt 0 ] || [ $TODO_LINES -gt 0 ]; then
  echo "⚠️  Manual review needed for debug output and TODO comments"
  echo "   See: /tmp/debug_files.txt and /tmp/todo_files.txt"
else
  echo "✅ Backend is production-clean!"
fi

echo ""
echo "Next: Run this script, then proceed to Chunk 4 (Frontend cleanup)"
