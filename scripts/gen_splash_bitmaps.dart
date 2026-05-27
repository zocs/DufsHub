// Generates "DufsHub" splash bitmaps for Android at multiple densities.
// Usage: dart run scripts/gen_splash_bitmaps.dart
//
// Renders PressStart2P-style monochrome pixel bitmaps (no font dependency).
// Each letter is drawn as a grid of filled rectangles matching the pixel font style.

import 'dart:io';
import 'dart:typed_data';

// 8x8 pixel bitmaps for letters D, u, f, s, H, b in PressStart2P style.
// Each letter is 8 rows; each row is 8 bits with MSB = leftmost pixel.
// Capitals (D, H) span rows 1-6; lowercase ascenders (f, b) span rows 0-6;
// short lowercase (u, s) span rows 2-6 — same vertical metrics as the
// original "inout" 5-letter font for visual consistency.
const _D = [0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x7C, 0x00];
const _u = [0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00];
const _f = [0x3C, 0x30, 0x7C, 0x30, 0x30, 0x30, 0x30, 0x00];
const _s = [0x00, 0x00, 0x3C, 0x60, 0x3C, 0x06, 0x78, 0x00];
const _H = [0x00, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00];
const _b = [0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00];

// "DufsHub"
final _letters = [_D, _u, _f, _s, _H, _u, _b];

/// Generate a raw RGBA PNG (very simple, no compression library needed).
/// Uses a minimal PNG encoder — just enough for solid-color pixel art.
List<int> _generatePng(int width, int height, List<int> rgba) {
  final buf = <int>[];

  // PNG signature
  buf.addAll([137, 80, 78, 71, 13, 10, 26, 10]);

  // IHDR
  final ihdr = BytesBuilder();
  ihdr.add(_u32(width));
  ihdr.add(_u32(height));
  ihdr.add([8]); // bit depth
  ihdr.add([6]); // color type: RGBA
  ihdr.add([0, 0, 0]); // compression, filter, interlace
  _addChunk(buf, 'IHDR', ihdr.toBytes());

  // IDAT — filter byte 0 (None) per row + raw pixel data
  final raw = BytesBuilder();
  for (int y = 0; y < height; y++) {
    raw.addByte(0); // filter: None
    for (int x = 0; x < width; x++) {
      final idx = (y * width + x) * 4;
      raw.add(rgba.sublist(idx, idx + 4));
    }
  }
  _addChunk(buf, 'IDAT', _zlibRawDeflate(raw.toBytes()));

  // IEND
  _addChunk(buf, 'IEND', []);

  return buf;
}

List<int> _u32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

void _addChunk(List<int> png, String type, List<int> data) {
  final chunk = BytesBuilder();
  chunk.add(type.codeUnits);
  chunk.add(data);
  final crc = _crc32(chunk.toBytes());
  png.addAll(_u32(data.length));
  png.addAll(type.codeUnits);
  png.addAll(data);
  png.addAll(_u32(crc));
}

// Minimal zlib deflate (store mode — no compression, but valid)
List<int> _zlibRawDeflate(List<int> data) {
  final out = BytesBuilder();
  // zlib header
  out.addByte(0x78); // CMF
  out.addByte(0x01); // FLG (no dict, fastest)
  // deflate store blocks
  const maxBlock = 65535;
  int offset = 0;
  while (offset < data.length) {
    final len = (data.length - offset > maxBlock) ? maxBlock : data.length - offset;
    final isLast = (offset + len >= data.length);
    out.addByte(isLast ? 1 : 0); // BFINAL
    out.addByte(len & 0xFF);
    out.addByte((len >> 8) & 0xFF);
    out.addByte((~len) & 0xFF);
    out.addByte(((~len) >> 8) & 0xFF);
    out.add(data.sublist(offset, offset + len));
    offset += len;
  }
  // Adler-32
  int a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  out.addByte((b >> 8) & 0xFF);
  out.addByte(b & 0xFF);
  out.addByte((a >> 8) & 0xFF);
  out.addByte(a & 0xFF);
  return out.toBytes();
}

int _crc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// Render "DufsHub" at the given pixel scale (each font pixel = scale × scale screen pixels).
/// Returns the raw RGBA pixel buffer and dimensions.
(List<int> rgba, int w, int h) _renderDufsHub(int scale, int r, int g, int b, int a) {
  const gap = 1; // gap between letters in font-pixels
  const letterW = 8;
  const letterH = 8;
  final numLetters = _letters.length;
  // Total width in font-pixels
  final totalFontW = numLetters * letterW + (numLetters - 1) * gap;
  const totalFontH = letterH;

  final pxW = totalFontW * scale;
  final pxH = totalFontH * scale;
  final rgba = Uint8List(pxW * pxH * 4);

  // Fill with transparent
  for (int i = 0; i < rgba.length; i += 4) {
    rgba[i + 3] = 0;
  }

  // Draw each letter
  for (int li = 0; li < numLetters; li++) {
    final letter = _letters[li];
    final offsetX = li * (letterW + gap) * scale;
    for (int row = 0; row < letterH; row++) {
      final bits = letter[row];
      for (int col = 0; col < letterW; col++) {
        if ((bits & (0x80 >> col)) != 0) {
          // Fill scale×scale block
          for (int sy = 0; sy < scale; sy++) {
            for (int sx = 0; sx < scale; sx++) {
              final px = offsetX + col * scale + sx;
              final py = row * scale + sy;
              final idx = (py * pxW + px) * 4;
              rgba[idx] = r;
              rgba[idx + 1] = g;
              rgba[idx + 2] = b;
              rgba[idx + 3] = a;
            }
          }
        }
      }
    }
  }

  return (rgba, pxW, pxH);
}

void main() {
  final base = Directory('android/app/src/main/res');

  // Light mode: dark text on light background
  // Dark mode: light text on dark background
  final configs = [
    {'dir': 'drawable', 'r': 40, 'g': 40, 'b': 40, 'a': 200},       // light
    {'dir': 'drawable-night', 'r': 230, 'g': 230, 'b': 230, 'a': 200}, // dark
  ];

  // Android density buckets: name → scale factor (relative to mdpi)
  final densities = {
    'mdpi': 1,
    'hdpi': 2,
    'xhdpi': 3,
    'xxhdpi': 4,
    'xxxhdpi': 6,
  };

  // Target visual width at mdpi (≈ 56% of a typical 360dp-wide phone). Auto-
  // derive baseScale from this so the splash stays comfortably inside the
  // screen no matter how many letters we render — change the letter set and
  // the script self-balances. (Previously baseScale was hard-coded to 5,
  // which was fine for "inout" (5 letters) but pushed "DufsHub" (7 letters)
  // right to the screen edges.)
  const targetMdpiWidthPx = 200;
  const gap = 1; // must match _renderDufsHub
  const letterW = 8;
  final numLetters = _letters.length;
  final totalFontW = numLetters * letterW + (numLetters - 1) * gap;
  final baseScale = (targetMdpiWidthPx ~/ totalFontW).clamp(2, 8);
  // "DufsHub" 7 letters → 62 font-px → baseScale=3 → 186×24px @ mdpi.
  // (Historical "inout" 5 letters → 44 font-px → baseScale=4 → 176×32px @ mdpi.)
  print('Letters: $numLetters, totalFontW: $totalFontW, baseScale: $baseScale');

  for (final cfg in configs) {
    final dir = cfg['dir'] as String;
    final r = cfg['r'] as int;
    final g = cfg['g'] as int;
    final b = cfg['b'] as int;
    final a = cfg['a'] as int;

    for (final entry in densities.entries) {
      final densityName = entry.key;
      final densityFactor = entry.value;
      final scale = baseScale * densityFactor;

      final (rgba, w, h) = _renderDufsHub(scale, r, g, b, a);
      final png = _generatePng(w, h, rgba);

      final outDir = Directory('${base.path}/${dir}-${densityName}');
      if (!outDir.existsSync()) outDir.createSync(recursive: true);

      final outFile = File('${outDir.path}/splash_dufshub.png');
      outFile.writeAsBytesSync(png);
      print('  ✓ ${outDir.path}/splash_dufshub.png (${w}×${h}px)');
    }
  }

  // Also generate a single drawable fallback (mdpi)
  for (final cfg in configs) {
    final dir = cfg['dir'] as String;
    final r = cfg['r'] as int;
    final g = cfg['g'] as int;
    final b = cfg['b'] as int;
    final a = cfg['a'] as int;
    final (rgba, w, h) = _renderDufsHub(baseScale, r, g, b, a);
    final png = _generatePng(w, h, rgba);

    final outDir = Directory('${base.path}/$dir');
    if (!outDir.existsSync()) outDir.createSync(recursive: true);
    final outFile = File('${outDir.path}/splash_dufshub.png');
    outFile.writeAsBytesSync(png);
    print('  ✓ ${outDir.path}/splash_dufshub.png (${w}×${h}px)');
  }

  print('\nDone! Generated splash bitmaps for all densities.');
}
