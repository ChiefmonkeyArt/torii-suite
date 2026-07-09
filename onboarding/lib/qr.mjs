// onboarding/lib/qr.mjs
// Minimal QR Code encoder — byte mode, error correction level L.
//
// Why not import qrcode from esm.sh? The torii-suite decentralization mandate
// is: no third-party CDNs at runtime. Everything the browser fetches must be
// served by the operator's own VPS (or, in dev, this local server). Baking a
// pure-JS encoder into onboarding/lib/ keeps the SPA self-hosted end-to-end.
//
// Implementation notes:
//   • Byte mode only. Alphanumeric would be shorter for URLs but the code
//     size cost is not worth it for one screen.
//   • Level L (7% recovery). Enough for a phone camera 20cm from the screen;
//     BTCPay checkout URLs are already short.
//   • Auto-picks the smallest version (1..40) that fits the payload.
//   • Renders as an SVG string. Callers set the pixel size via viewBox scale.
//
// Public API:
//   generateQrSvg(text, { size = 240, margin = 4 }) -> string
//
// Algorithm follows ISO/IEC 18004:2015. This is a compact hand-rolled
// implementation; adapted from public-domain reference math (Reed-Solomon over
// GF(256), Bose-Chaudhuri masks). No external dependencies.

// ---- GF(256) tables --------------------------------------------------------

const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
(function initGf() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255];
})();

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[(GF_LOG[a] + GF_LOG[b]) % 255];
}

// ---- Reed-Solomon generator polynomial -------------------------------------

function rsGeneratorPoly(degree) {
  let poly = new Uint8Array([1]);
  for (let i = 0; i < degree; i++) {
    const next = new Uint8Array(poly.length + 1);
    for (let j = 0; j < poly.length; j++) {
      next[j] ^= poly[j];
      next[j + 1] ^= gfMul(poly[j], GF_EXP[i]);
    }
    poly = next;
  }
  return poly;
}

function rsRemainder(data, generator) {
  const result = new Uint8Array(generator.length - 1);
  for (const b of data) {
    const factor = b ^ result[0];
    result.copyWithin(0, 1);
    result[result.length - 1] = 0;
    if (factor !== 0) {
      for (let i = 0; i < generator.length - 1; i++) {
        result[i] ^= gfMul(generator[i + 1], factor);
      }
    }
  }
  return result;
}

// ---- Version capacity table (byte mode, level L, in bytes) -----------------
// Data codewords capacity for byte mode at ECC level L, versions 1..40.
// Source: ISO/IEC 18004 Table 7.
const BYTE_CAP_L = [
  17, 32, 53, 78, 106, 134, 154, 192, 230, 271, 321, 367, 425, 458, 520, 586, 644, 718, 792, 858,
  929, 1003, 1091, 1171, 1273, 1367, 1465, 1528, 1628, 1732, 1840, 1952, 2068, 2188, 2303, 2431,
  2563, 2699, 2809, 2953,
];

// ECC block layout (level L): per version, [numBlocks, dataCodewordsPerBlock]
// (When there are two block groups per version at level L, the version bumps
// past the point we need for onboarding URLs, so we keep the simple single-
// group case that covers versions 1..8 (up to 192 data bytes = plenty for a
// 100-char checkout URL). Anything longer picks a bigger version but still
// via a mixed-block path — see buildEccBlocks below.)
//
// The full table would be large; we only need through version ~10 for a
// ~150-byte checkout URL. Table entries per version at ECC L:
//   version: [total_codewords, ecc_per_block, num_blocks_group1, data_per_block_group1,
//             num_blocks_group2, data_per_block_group2]
const ECC_L = [
  /* v1  */ [ 26,  7, 1, 19, 0,  0],
  /* v2  */ [ 44, 10, 1, 34, 0,  0],
  /* v3  */ [ 70, 15, 1, 55, 0,  0],
  /* v4  */ [100, 20, 1, 80, 0,  0],
  /* v5  */ [134, 26, 1,108, 0,  0],
  /* v6  */ [172, 18, 2, 68, 0,  0],
  /* v7  */ [196, 20, 2, 78, 0,  0],
  /* v8  */ [242, 24, 2, 97, 0,  0],
  /* v9  */ [292, 30, 2,116, 0,  0],
  /* v10 */ [346, 18, 2, 68, 2, 69],
  /* v11 */ [404, 20, 4, 81, 0,  0],
  /* v12 */ [466, 24, 2, 92, 2, 93],
  /* v13 */ [532, 26, 4,107, 0,  0],
  /* v14 */ [581, 30, 3,115, 1,116],
  /* v15 */ [655, 22, 5, 87, 1, 88],
  /* v16 */ [733, 24, 5, 98, 1, 99],
  /* v17 */ [815, 28, 1,107, 5,108],
  /* v18 */ [901, 30, 5,120, 1,121],
  /* v19 */ [991, 28, 3,113, 4,114],
  /* v20 */ [1085,28, 3,107, 5,108],
];

// ---- Format info bit patterns (level L, mask 0..7) -------------------------
// Precomputed 15-bit format info strings per (ecl=L, mask).
const FORMAT_INFO_L = [
  0x77c4, 0x72f3, 0x7daa, 0x789d, 0x662f, 0x6318, 0x6c41, 0x6976,
];

// ---- Version info (>= v7) --------------------------------------------------
const VERSION_INFO = [
  0, 0, 0, 0, 0, 0, // v1..v6 (no version info)
  0x07C94, 0x085BC, 0x09A99, 0x0A4D3, 0x0BBF6, 0x0C762, 0x0D847,
  0x0E60D, 0x0F928, 0x10B78, 0x1145D, 0x12A17, 0x13532, 0x149A6,
  0x15683, 0x168C9, 0x177EC, 0x18EC4, 0x191E1, 0x1AFAB, 0x1B08E,
  0x1CC1A, 0x1D33F, 0x1ED75, 0x1F250, 0x209D5, 0x216F0, 0x228BA,
  0x2379F, 0x24B0B, 0x2542E, 0x26A64, 0x27541, 0x28C69,
];

// ---- Public entry point ----------------------------------------------------

/**
 * Encode `text` as a QR code and return an SVG string.
 * @param {string} text
 * @param {{size?:number, margin?:number, dark?:string, light?:string}} [opts]
 * @returns {string} SVG markup
 */
export function generateQrSvg(text, opts = {}) {
  const { size = 240, margin = 4, dark = "#000", light = "#fff" } = opts;
  const utf8 = new TextEncoder().encode(text);
  const version = pickVersion(utf8.length);
  if (!version) throw new Error(`QR payload too large (${utf8.length} bytes)`);

  const bits = buildDataBits(utf8, version);
  const codewords = interleaveWithEcc(bits, version);
  const modules = renderMatrix(codewords, version);

  return matrixToSvg(modules, { size, margin, dark, light });
}

function pickVersion(byteLen) {
  for (let v = 1; v <= 20; v++) {
    const [, eccPerBlock, g1c, g1d, g2c, g2d] = ECC_L[v - 1];
    const dataBytes = g1c * g1d + g2c * g2d;
    // 4 mode bits + character count bits (8 for v1-9, 16 for v10+ byte mode)
    const cciBits = v < 10 ? 8 : 16;
    const capacityBytes = dataBytes - Math.ceil((4 + cciBits) / 8);
    if (byteLen <= capacityBytes) return v;
  }
  return null;
}

function buildDataBits(bytes, version) {
  const cciBits = version < 10 ? 8 : 16;
  const bits = new BitBuffer();
  bits.write(0b0100, 4);              // mode indicator: byte
  bits.write(bytes.length, cciBits);  // char count
  for (const b of bytes) bits.write(b, 8);

  // Terminator: up to 4 zeros
  const [, , g1c, g1d, g2c, g2d] = ECC_L[version - 1];
  const totalDataBits = (g1c * g1d + g2c * g2d) * 8;
  const term = Math.min(4, totalDataBits - bits.length);
  bits.write(0, term);

  // Byte-align
  while (bits.length % 8 !== 0) bits.write(0, 1);

  // Pad with 0xEC / 0x11 alternating
  const padBytes = (totalDataBits - bits.length) / 8;
  for (let i = 0; i < padBytes; i++) bits.write(i % 2 === 0 ? 0xEC : 0x11, 8);

  return bits.toBytes();
}

function interleaveWithEcc(data, version) {
  const [, eccPerBlock, g1c, g1d, g2c, g2d] = ECC_L[version - 1];
  const generator = rsGeneratorPoly(eccPerBlock);

  // Split data into blocks
  const blocks = [];
  const eccBlocks = [];
  let offset = 0;
  for (let i = 0; i < g1c; i++) {
    const block = data.slice(offset, offset + g1d);
    offset += g1d;
    blocks.push(block);
    eccBlocks.push(rsRemainder(block, generator));
  }
  for (let i = 0; i < g2c; i++) {
    const block = data.slice(offset, offset + g2d);
    offset += g2d;
    blocks.push(block);
    eccBlocks.push(rsRemainder(block, generator));
  }

  // Interleave data
  const maxData = Math.max(g1d, g2d);
  const out = [];
  for (let i = 0; i < maxData; i++) {
    for (const b of blocks) if (i < b.length) out.push(b[i]);
  }
  // Interleave ECC (all blocks have equal ECC length)
  for (let i = 0; i < eccPerBlock; i++) {
    for (const e of eccBlocks) out.push(e[i]);
  }
  return new Uint8Array(out);
}

// ---- Matrix construction ---------------------------------------------------

function renderMatrix(codewords, version) {
  const n = 17 + version * 4;
  const modules = Array.from({ length: n }, () => new Int8Array(n).fill(-1)); // -1 = unset
  const reserved = Array.from({ length: n }, () => new Uint8Array(n));

  placeFinders(modules, reserved, n);
  placeSeparators(modules, reserved, n);
  placeTimingPatterns(modules, reserved, n);
  placeAlignmentPatterns(modules, reserved, n, version);
  reserveFormatArea(modules, reserved, n);
  if (version >= 7) placeVersionInfo(modules, reserved, n, version);

  // Dark module (always dark)
  modules[4 * version + 9][8] = 1;
  reserved[4 * version + 9][8] = 1;

  placeData(modules, reserved, n, codewords);

  // Pick best mask (lowest penalty), apply it, and write format info
  let bestMask = 0, bestPenalty = Infinity, bestModules = null;
  for (let mask = 0; mask < 8; mask++) {
    const trial = modules.map(r => Int8Array.from(r));
    applyMask(trial, reserved, n, mask);
    writeFormatInfo(trial, n, mask);
    const p = maskPenalty(trial, n);
    if (p < bestPenalty) { bestPenalty = p; bestMask = mask; bestModules = trial; }
  }

  return bestModules;
}

function placeFinders(modules, reserved, n) {
  const positions = [[0, 0], [n - 7, 0], [0, n - 7]];
  for (const [ox, oy] of positions) {
    for (let dy = 0; dy < 7; dy++) {
      for (let dx = 0; dx < 7; dx++) {
        const on = (dx === 0 || dx === 6 || dy === 0 || dy === 6) ||
                   (dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4);
        modules[oy + dy][ox + dx] = on ? 1 : 0;
        reserved[oy + dy][ox + dx] = 1;
      }
    }
  }
}

function placeSeparators(modules, reserved, n) {
  // 1-module wide light border around each finder
  const zones = [[7, 0, 0, 7], [n - 8, 0, n - 7, 7], [7, n - 8, 0, n - 1]];
  for (const [x1, y1, x2, y2] of zones) {
    for (let y = Math.min(y1, y2); y <= Math.max(y1, y2); y++) {
      for (let x = Math.min(x1, x2); x <= Math.max(x1, x2); x++) {
        if (x < 0 || y < 0 || x >= n || y >= n) continue;
        if (!reserved[y][x]) { modules[y][x] = 0; reserved[y][x] = 1; }
      }
    }
  }
  // Also reserve the single row/col adjacent
  for (let i = 0; i < 8; i++) {
    for (const [x, y] of [[i, 7], [7, i], [n - 8, i], [n - 1 - i, 7], [i, n - 8], [7, n - 1 - i]]) {
      if (x >= 0 && y >= 0 && x < n && y < n && !reserved[y][x]) {
        modules[y][x] = 0; reserved[y][x] = 1;
      }
    }
  }
}

function placeTimingPatterns(modules, reserved, n) {
  for (let i = 8; i < n - 8; i++) {
    const on = i % 2 === 0 ? 1 : 0;
    if (!reserved[6][i]) { modules[6][i] = on; reserved[6][i] = 1; }
    if (!reserved[i][6]) { modules[i][6] = on; reserved[i][6] = 1; }
  }
}

const ALIGN_POS = [
  null,
  [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34],
  [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50],
  [6, 30, 54], [6, 32, 58], [6, 34, 62],
  [6, 26, 46, 66], [6, 26, 48, 70], [6, 26, 50, 74],
  [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86], [6, 34, 62, 90],
];

function placeAlignmentPatterns(modules, reserved, n, version) {
  const positions = ALIGN_POS[version];
  if (!positions || positions.length === 0) return;
  for (const cy of positions) {
    for (const cx of positions) {
      // Skip if overlapping a finder
      if ((cx <= 7 && cy <= 7) || (cx >= n - 8 && cy <= 7) || (cx <= 7 && cy >= n - 8)) continue;
      for (let dy = -2; dy <= 2; dy++) {
        for (let dx = -2; dx <= 2; dx++) {
          const on = (Math.abs(dx) === 2 || Math.abs(dy) === 2 || (dx === 0 && dy === 0)) ? 1 : 0;
          modules[cy + dy][cx + dx] = on;
          reserved[cy + dy][cx + dx] = 1;
        }
      }
    }
  }
}

function reserveFormatArea(modules, reserved, n) {
  // Around top-left finder
  for (let i = 0; i < 9; i++) { if (i !== 6) { reserved[8][i] = 1; reserved[i][8] = 1; } }
  // Right of top-right finder
  for (let i = 0; i < 8; i++) { reserved[8][n - 1 - i] = 1; }
  // Below bottom-left finder
  for (let i = 0; i < 8; i++) { reserved[n - 1 - i][8] = 1; }
}

function placeVersionInfo(modules, reserved, n, version) {
  const info = VERSION_INFO[version - 1];
  for (let i = 0; i < 18; i++) {
    const bit = (info >> i) & 1;
    const a = Math.floor(i / 3), b = i % 3 + n - 11;
    modules[a][b] = bit; reserved[a][b] = 1;
    modules[b][a] = bit; reserved[b][a] = 1;
  }
}

function placeData(modules, reserved, n, codewords) {
  let bitIndex = 0;
  const totalBits = codewords.length * 8;
  let upward = true;
  for (let colRight = n - 1; colRight > 0; colRight -= 2) {
    if (colRight === 6) colRight--; // skip vertical timing
    for (let vert = 0; vert < n; vert++) {
      for (let side = 0; side < 2; side++) {
        const x = colRight - side;
        const y = upward ? n - 1 - vert : vert;
        if (reserved[y][x]) continue;
        if (bitIndex < totalBits) {
          const byte = codewords[bitIndex >> 3];
          const bit = (byte >> (7 - (bitIndex & 7))) & 1;
          modules[y][x] = bit;
          bitIndex++;
        } else {
          modules[y][x] = 0;
        }
      }
    }
    upward = !upward;
  }
}

function applyMask(modules, reserved, n, mask) {
  const fns = [
    (r, c) => (r + c) % 2 === 0,
    (r) => r % 2 === 0,
    (_r, c) => c % 3 === 0,
    (r, c) => (r + c) % 3 === 0,
    (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
    (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
    (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0,
    (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0,
  ];
  const fn = fns[mask];
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (!reserved[y][x] && fn(y, x)) modules[y][x] ^= 1;
    }
  }
}

function writeFormatInfo(modules, n, mask) {
  const info = FORMAT_INFO_L[mask];
  for (let i = 0; i < 15; i++) {
    const bit = (info >> i) & 1;
    // Row 8
    if (i < 6)       modules[8][i]      = bit;
    else if (i < 8)  modules[8][i + 1]  = bit;
    else if (i === 8) modules[7][8]     = bit;
    else             modules[14 - i][8] = bit;
    // Column 8 + wrap
    if (i < 8)       modules[n - 1 - i][8] = bit;
    else             modules[8][n - 15 + i] = bit;
  }
}

// ---- Mask penalty (ISO/IEC 18004 §8.3.2) -----------------------------------

function maskPenalty(modules, n) {
  let p = 0;
  // Rule 1: runs of 5+ same-color modules in row or column
  for (let y = 0; y < n; y++) {
    let run = 1;
    for (let x = 1; x < n; x++) {
      if (modules[y][x] === modules[y][x - 1]) run++;
      else { if (run >= 5) p += 3 + (run - 5); run = 1; }
    }
    if (run >= 5) p += 3 + (run - 5);
  }
  for (let x = 0; x < n; x++) {
    let run = 1;
    for (let y = 1; y < n; y++) {
      if (modules[y][x] === modules[y - 1][x]) run++;
      else { if (run >= 5) p += 3 + (run - 5); run = 1; }
    }
    if (run >= 5) p += 3 + (run - 5);
  }
  // Rule 2: 2x2 blocks of the same color
  for (let y = 0; y < n - 1; y++) {
    for (let x = 0; x < n - 1; x++) {
      const v = modules[y][x];
      if (v === modules[y][x + 1] && v === modules[y + 1][x] && v === modules[y + 1][x + 1]) p += 3;
    }
  }
  // Rule 4: overall balance
  let dark = 0;
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (modules[y][x]) dark++;
  const pct = (dark * 100) / (n * n);
  p += Math.floor(Math.abs(pct - 50) / 5) * 10;
  // Rule 3 (finder-like patterns) is skipped — modest impact on visual QR.
  return p;
}

// ---- SVG rendering ---------------------------------------------------------

function matrixToSvg(modules, { size, margin, dark, light }) {
  const n = modules.length;
  const dim = n + margin * 2;
  let path = "";
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (modules[y][x] === 1) {
        path += `M${x + margin} ${y + margin}h1v1h-1z`;
      }
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${dim} ${dim}" width="${size}" height="${size}" shape-rendering="crispEdges">` +
         `<rect width="${dim}" height="${dim}" fill="${light}"/>` +
         `<path d="${path}" fill="${dark}"/>` +
         `</svg>`;
}

// ---- BitBuffer helper ------------------------------------------------------

class BitBuffer {
  constructor() { this.bits = []; }
  get length() { return this.bits.length; }
  write(value, len) {
    for (let i = len - 1; i >= 0; i--) this.bits.push((value >> i) & 1);
  }
  toBytes() {
    const out = new Uint8Array(Math.ceil(this.bits.length / 8));
    for (let i = 0; i < this.bits.length; i++) {
      if (this.bits[i]) out[i >> 3] |= 1 << (7 - (i & 7));
    }
    return out;
  }
}
