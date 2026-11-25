#!/usr/bin/env node
// Renders icons from the public @bitrise/bitkit-v2 package (MIT) into square SVG tiles
// that Godot can import as textures. The output is committed, so the game builds without
// node_modules; re-run this only when you change the mapping below.
//
//   node scripts/build-icons.mjs

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const svgDir = resolve(root, 'node_modules/@bitrise/bitkit-v2/dist/svgs/24x24');
const outDir = resolve(root, 'game/assets/icons');

// Bitkit primitive colours (lib/theme/tokens/colors.ts).
const C = {
  purple40: '#7b3ba5',
  purple50: '#9247c2',
  turquoise50: '#009e8e',
  red50: '#d72d40',
  blue50: '#2582d0',
  orange60: '#ed720c',
  yellow60: '#d6a200',
  green50: '#2a9d4c',
  neutral30: '#49404f',
};

// file name in the game -> [Bitkit icon, tile background]
const ICONS = {
  // Gameplay icons. Swap the Bitkit icon name here to change what a box shows.
  boost: ['build-cache-filled', C.turquoise50],
  obstacle: ['bug', C.red50],
  ramp: ['remote-access', C.blue50],
  finish: ['release-filled', C.purple50],
  // Trackside decoration.
  bitbot: ['bitbot', C.purple40],
  'badge-bitrise': ['badge-bitrise', C.purple50],
  ci: ['ci-filled', C.green50],
  insights: ['insights-filled', C.orange60],
  'build-hub': ['build-hub-filled', C.blue50],
  // Bitrise RDE (remote development environments), the same icon the ramp uses.
  rde: ['remote-access', C.purple40],
  'code-push': ['code-push', C.turquoise50],
  coffee: ['coffee', C.neutral30],
  stopwatch: ['stopwatch', C.yellow60],
  crown: ['crown', C.yellow60],
  siren: ['siren', C.red50],
};

const SIZE = 256;
const PAD = 44;
const scale = (SIZE - PAD * 2) / 24;

mkdirSync(outDir, { recursive: true });

/** The inner markup of a 24x24 Bitkit icon, drawn in white. */
async function iconMarkup(icon) {
  const mod = await import(pathToFileURL(resolve(svgDir, `icon-${icon}-24.js`)).href);
  return renderToStaticMarkup(createElement(mod.default))
    .replace(/^<svg[^>]*>/, '')
    .replace(/<\/svg>$/, '')
    .replaceAll('currentColor', '#ffffff');
}

for (const [name, [icon, background]] of Object.entries(ICONS)) {
  const inner = await iconMarkup(icon);

  const tile = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">`,
    `<rect width="${SIZE}" height="${SIZE}" fill="${background}"/>`,
    `<rect x="9" y="9" width="${SIZE - 18}" height="${SIZE - 18}" rx="26" fill="none" stroke="#ffffff" stroke-opacity="0.4" stroke-width="6"/>`,
    `<g transform="translate(${PAD} ${PAD}) scale(${scale.toFixed(4)})" fill="#ffffff">${inner}</g>`,
    '</svg>',
    '',
  ].join('\n');

  writeFileSync(resolve(outDir, `${name}.svg`), tile);
  console.log(`${name}.svg  <-  icon-${icon}-24`);
}

// The ramp's driving surface: yellow chevrons pointing up the slope, hazard stripes on both
// edges and the ramp icon in the middle. The top of the image is the top of the ramp.
{
  const W = 256;
  const H = 512;
  const parts = [`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`];
  parts.push(`<rect width="${W}" height="${H}" fill="#2b0e3f"/>`);
  for (const x of [0, W - 26]) {
    parts.push(`<rect x="${x}" y="0" width="26" height="${H}" fill="#201b22"/>`);
    for (let y = -26; y < H; y += 36) {
      parts.push(`<path d="M${x} ${y + 18} L${x + 26} ${y} L${x + 26} ${y + 18} L${x} ${y + 36} Z" fill="${'#f9cc15'}"/>`);
    }
  }
  for (const y of [28, 118, 372, 452]) {
    parts.push(`<path d="M52 ${y + 44} L128 ${y} L204 ${y + 44} L204 ${y + 74} L128 ${y + 30} L52 ${y + 74} Z" fill="#f9cc15"/>`);
  }
  parts.push(`<rect x="62" y="190" width="132" height="132" rx="18" fill="${C.blue50}"/>`);
  parts.push(`<g transform="translate(74 202) scale(4.5)" fill="#ffffff">${await iconMarkup(ICONS.ramp[0])}</g>`);
  parts.push('</svg>', '');
  writeFileSync(resolve(outDir, 'ramp-deck.svg'), parts.join('\n'));
  console.log('ramp-deck.svg  <-  icon-' + ICONS.ramp[0] + '-24');
}

// The roundel on every car's roof: the Bitrise badge on a white disc with a dark ring, so it
// shows up whatever colour the car is painted. The top of the image faces the front of the car.
{
  const parts = [`<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">`];
  parts.push(`<circle cx="128" cy="128" r="124" fill="#ffffff"/>`);
  parts.push(`<circle cx="128" cy="128" r="112" fill="none" stroke="#2b0e3f" stroke-width="6"/>`);
  parts.push(`<g transform="translate(26 26) scale(8.5)">${await iconMarkup('badge-bitrise')}</g>`);
  parts.push('</svg>', '');
  writeFileSync(resolve(outDir, 'car-roof.svg'), parts.join('\n'));
  console.log('car-roof.svg  <-  icon-badge-bitrise-24');
}
