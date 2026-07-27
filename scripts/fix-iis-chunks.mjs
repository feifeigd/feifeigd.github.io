#!/usr/bin/env node
/**
 * Post-build fix: replace '~' in chunk filenames with '-'
 * IIS treats '~' as DOS 8.3 short filename → 403 Forbidden
 */
import { readFileSync, writeFileSync, renameSync, readdirSync, existsSync, statSync } from 'fs';
import { join } from 'path';

const BUILD_DIR = 'build';
const ASSETS_JS = join(BUILD_DIR, 'assets', 'js');

// Recursively find all HTML files
function findHtmlFiles(dir) {
  const results = [];
  for (const entry of readdirSync(dir)) {
    const fullPath = join(dir, entry);
    const stat = statSync(fullPath);
    if (stat.isDirectory()) {
      results.push(...findHtmlFiles(fullPath));
    } else if (entry.endsWith('.html')) {
      results.push(fullPath);
    }
  }
  return results;
}

// Step 1: Collect rename mapping
const renames = [];
if (existsSync(ASSETS_JS)) {
  for (const file of readdirSync(ASSETS_JS)) {
    if (file.includes('~')) {
      const newName = file.replace(/~/g, '-');
      renames.push({ old: file, new: newName });
    }
  }
}

if (renames.length === 0) {
  console.log('No files with "~" found. Nothing to fix.');
  process.exit(0);
}

// Step 2: Rename files
for (const { old, new: newName } of renames) {
  renameSync(join(ASSETS_JS, old), join(ASSETS_JS, newName));
  console.log(`Renamed: ${old} → ${newName}`);
}

// Step 3: Fix references in all HTML files
const htmlFiles = findHtmlFiles(BUILD_DIR);
let totalFixed = 0;
for (const htmlFile of htmlFiles) {
  let content = readFileSync(htmlFile, 'utf-8');
  let changed = false;
  for (const { old, new: newName } of renames) {
    if (content.includes(old)) {
      content = content.replaceAll(old, newName);
      changed = true;
    }
  }
  if (changed) {
    writeFileSync(htmlFile, content);
    totalFixed++;
    console.log(`Fixed references in: ${htmlFile}`);
  }
}

console.log(`\nDone! Renamed ${renames.length} file(s), updated ${totalFixed} HTML file(s).`);
