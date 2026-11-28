#!/usr/bin/env node
/*
 * Draw YAFC's Hero view icon. The artwork is original to YAFC: a camera body
 * inside a 360 orbit, with two rotation arrowheads. It is not traced, sampled
 * or assembled from Ford's icons.
 *
 * IconPushButton resolves `parkingfeatures/icon_hero_view` to
 * ford-10P-MY20/icons/<theme>/50x50/parkingfeatures/icon_hero_view_<state>.png
 * and appends the state suffix itself. Ten files: day and night, five states.
 *
 * Deterministic: fixed geometry, 8x supersampling, fixed zlib settings, no
 * timestamps or ancillary chunks. Run `node tools/make-hero-icon.js` from the
 * yafc repository to regenerate payload/hmi/icons; the committed PNGs, not the
 * generator, are what the installer ships and hashes.
 */
'use strict';

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const SIZE = 50;
const SCALE = 8;
const W = SIZE * SCALE;
const OUT = path.resolve(process.argv[2] || path.join(__dirname, '..', 'payload/hmi/icons'));

// Theme colours: the day glyph is dark on light chrome, the night glyph light
// on the dark HMI. Pressed/selected use the HMI accent blue.
const STATES = {
  active:          { day: [59, 62, 63],    night: [215, 215, 215] },
  activepressed:   { day: [0, 65, 255],    night: [27, 148, 250]  },
  inactive:        { day: [179, 187, 190], night: [83, 82, 100]   },
  selected:        { day: [0, 65, 255],    night: [27, 148, 250]  },
  // The proven private icon uses the normal colour while a selected button is
  // pressed; keep that mapping instead of inventing a darker accent.
  selectedpressed: { day: [59, 62, 63],    night: [215, 215, 215] },
};

function mask() {
  return new Uint8Array(W * W);
}

function put(m, x, y) {
  if (x >= 0 && y >= 0 && x < W && y < W) m[y * W + x] = 1;
}

// A round-capped arc, angles in degrees, 0 = right, 90 = up.
function arc(m, cx, cy, r, a0, a1, width) {
  const steps = Math.ceil(Math.abs(a1 - a0) * SCALE / 1.2) + 12;
  const rad = width * SCALE / 2;
  const rr = r * SCALE;
  for (let i = 0; i <= steps; i++) {
    const a = (a0 + (a1 - a0) * i / steps) * Math.PI / 180;
    const x = cx * SCALE + rr * Math.cos(a);
    const y = cy * SCALE - rr * Math.sin(a);
    const x0 = Math.floor(x - rad), x1 = Math.ceil(x + rad);
    const y0 = Math.floor(y - rad), y1 = Math.ceil(y + rad);
    for (let py = y0; py <= y1; py++) {
      for (let px = x0; px <= x1; px++) {
        const dx = px + 0.5 - x, dy = py + 0.5 - y;
        if (dx * dx + dy * dy <= rad * rad) put(m, px, py);
      }
    }
  }
}

function triangle(m, p1, p2, p3) {
  const A = [p1[0] * SCALE, p1[1] * SCALE];
  const B = [p2[0] * SCALE, p2[1] * SCALE];
  const C = [p3[0] * SCALE, p3[1] * SCALE];
  const minx = Math.floor(Math.min(A[0], B[0], C[0]));
  const maxx = Math.ceil(Math.max(A[0], B[0], C[0]));
  const miny = Math.floor(Math.min(A[1], B[1], C[1]));
  const maxy = Math.ceil(Math.max(A[1], B[1], C[1]));
  const edge = (p, q, r) => (p[0] - r[0]) * (q[1] - r[1]) - (q[0] - r[0]) * (p[1] - r[1]);
  for (let y = miny; y <= maxy; y++) {
    for (let x = minx; x <= maxx; x++) {
      const P = [x + 0.5, y + 0.5];
      const d1 = edge(P, B, A), d2 = edge(P, C, B), d3 = edge(P, A, C);
      const neg = d1 < 0 || d2 < 0 || d3 < 0;
      const pos = d1 > 0 || d2 > 0 || d3 > 0;
      if (!(neg && pos)) put(m, x, y);
    }
  }
}

function roundedBox(m, x, y, w, h, r, thickness) {
  const ir = Math.max(0, r - thickness);
  const sdf = (px, py, xx, yy, ww, hh, rr) => {
    const cx = xx + ww / 2, cy = yy + hh / 2;
    const dx = Math.abs(px - cx) - (ww / 2 - rr);
    const dy = Math.abs(py - cy) - (hh / 2 - rr);
    const ax = Math.max(dx, 0), ay = Math.max(dy, 0);
    return Math.hypot(ax, ay) + Math.min(Math.max(dx, dy), 0) - rr;
  };
  for (let py = Math.floor(y * SCALE); py <= Math.ceil((y + h) * SCALE); py++) {
    for (let px = Math.floor(x * SCALE); px <= Math.ceil((x + w) * SCALE); px++) {
      const u = (px + 0.5) / SCALE, v = (py + 0.5) / SCALE;
      if (sdf(u, v, x, y, w, h, r) <= 0 &&
          sdf(u, v, x + thickness, y + thickness, w - 2 * thickness, h - 2 * thickness, ir) >= 0) {
        put(m, px, py);
      }
    }
  }
}

function ring(m, cx, cy, r, thickness) {
  for (let py = Math.floor((cy - r - thickness) * SCALE); py <= Math.ceil((cy + r + thickness) * SCALE); py++) {
    for (let px = Math.floor((cx - r - thickness) * SCALE); px <= Math.ceil((cx + r + thickness) * SCALE); px++) {
      const dx = (px + 0.5) / SCALE - cx;
      const dy = (py + 0.5) / SCALE - cy;
      if (Math.abs(Math.hypot(dx, dy) - r) <= thickness / 2) put(m, px, py);
    }
  }
}

function disc(m, cx, cy, r) {
  for (let py = Math.floor((cy - r) * SCALE); py <= Math.ceil((cy + r) * SCALE); py++) {
    for (let px = Math.floor((cx - r) * SCALE); px <= Math.ceil((cx + r) * SCALE); px++) {
      const dx = (px + 0.5) / SCALE - cx;
      const dy = (py + 0.5) / SCALE - cy;
      if (dx * dx + dy * dy <= r * r) put(m, px, py);
    }
  }
}

// Arrowhead at the arc end, pointing along the increasing-angle direction.
function arrow(m, angle, radius) {
  const rad = angle * Math.PI / 180;
  const p = [25 + radius * Math.cos(rad), 25 - radius * Math.sin(rad)];
  const t = [-Math.sin(rad), -Math.cos(rad)];
  const perp = [-t[1], t[0]];
  const tip = [p[0] + t[0] * 3.2, p[1] + t[1] * 3.2];
  const base = [p[0] - t[0] * 0.8, p[1] - t[1] * 0.8];
  triangle(m, tip,
    [base[0] + perp[0] * 2.8, base[1] + perp[1] * 2.8],
    [base[0] - perp[0] * 2.8, base[1] - perp[1] * 2.8]);
}

function artwork() {
  const m = mask();
  // 360 orbit, two arcs with a gap at each side, then the camera body.
  arc(m, 25, 25, 20.5, 35, 145, 2.8);
  arc(m, 25, 25, 20.5, 215, 325, 2.8);
  arrow(m, 35, 20.5);
  arrow(m, 215, 20.5);
  roundedBox(m, 14, 19, 22, 13, 3, 2.4);       // camera body
  roundedBox(m, 20, 14.5, 10, 6, 2.3, 2.2);    // viewfinder bump
  ring(m, 25, 25.5, 3.6, 2.0);                 // lens
  disc(m, 25, 25.5, 0.9);                      // lens centre
  return m;
}

function coverage(m) {
  const cov = new Uint16Array(SIZE * SIZE);
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      let n = 0;
      for (let sy = 0; sy < SCALE; sy++) {
        for (let sx = 0; sx < SCALE; sx++) {
          n += m[(y * SCALE + sy) * W + x * SCALE + sx];
        }
      }
      cov[y * SIZE + x] = n;
    }
  }
  return cov;
}

function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) {
    c ^= b;
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

function png(cov, colour) {
  const raw = Buffer.alloc(SIZE * (1 + SIZE * 4));
  let p = 0;
  for (let y = 0; y < SIZE; y++) {
    raw[p++] = 0;  // filter: none
    for (let x = 0; x < SIZE; x++) {
      raw[p++] = colour[0];
      raw[p++] = colour[1];
      raw[p++] = colour[2];
      raw[p++] = Math.round(cov[y * SIZE + x] * 255 / (SCALE * SCALE));
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(SIZE, 0);
  ihdr.writeUInt32BE(SIZE, 4);
  ihdr[8] = 8;   // bit depth
  ihdr[9] = 6;   // RGBA
  const idat = zlib.deflateSync(raw, {
    level: 9,
    strategy: zlib.constants.Z_DEFAULT_STRATEGY,
  });
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr),
    chunk('IDAT', idat),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const cov = coverage(artwork());
for (const theme of ['day', 'night']) {
  for (const [state, colours] of Object.entries(STATES)) {
    const rel = `${theme}/50x50/parkingfeatures/icon_hero_view_${state}.png`;
    const file = path.join(OUT, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const bytes = png(cov, colours[theme]);
    fs.writeFileSync(file, bytes);
    if (bytes.length < 200 || bytes[0] !== 0x89 || bytes.toString('ascii', 1, 4) !== 'PNG') {
      throw new Error(`not a PNG: ${file}`);
    }
    console.log(`${rel} (${bytes.length} bytes)`);
  }
}
