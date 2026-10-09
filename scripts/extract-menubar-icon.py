# Extracts the supra silhouette from the app icon for use as a macOS menu bar template.
# The icon is white-on-white: the tile background is a flat light gray and the car is
# white with gray shading, so "form" = every pixel that differs from the background
# level. The mask is dilated before downscaling so the thin outline closes into a body.
import zlib
import struct


SRC = "/Users/nilslin/dev/icons/supra_icon/AppIcon.iconset/icon_256x256.png"
OUT = "/Users/nilslin/dev/utils/crisp/Resources"


def read_png(path):
    data = open(path, "rb").read()
    pos, idat, w, h, ct = 8, b"", 0, 0, 0
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            w, h, _, ct = struct.unpack(">IIBB", chunk[:10])
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    raw = zlib.decompress(idat)
    bpp = 4 if ct == 6 else 3
    stride = w * bpp
    out = bytearray()
    prev = bytearray(stride)
    i = 0

    def paeth(a, b, c):
        p = a + b - c
        pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
        return a if pa <= pb and pa <= pc else (b if pb <= pc else c)

    for _ in range(h):
        f = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        if f == 1:
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 255
        elif f == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                line[x] = (line[x] + ((line[x - bpp] if x >= bpp else 0) + prev[x]) // 2) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + paeth(a, prev[x], prev[x - bpp] if x >= bpp else 0)) & 255
        out += line
        prev = line
    return w, h, bpp, stride, out


def write_png(path, width, height, rgba):
    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    raw = b"".join(b"\x00" + bytes(rgba[y * width * 4:(y + 1) * width * 4]) for y in range(height))
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n"
                           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9))
                           + chunk(b"IEND", b""))


w, h, bpp, stride, px = read_png(SRC)

# The tile is a black rounded square on a white canvas with a white car on top.
# Outside = white pixels that touch no black pixel (the canvas corners).
bright = [[0] * w for _ in range(h)]
dark = [[0] * w for _ in range(h)]
for y in range(h):
    for x in range(w):
        o = y * stride + x * bpp
        alpha = px[o + 3] if bpp == 4 else 255
        if alpha < 250:
            bright[y][x] = dark[y][x] = 0
            continue
        luminance = (px[o] * 299 + px[o + 1] * 587 + px[o + 2] * 114) // 1000
        bright[y][x] = 1 if luminance >= 120 else 0
        dark[y][x] = 1 if luminance <= 60 else 0

ink = [[0] * w for _ in range(h)]
for y in range(h):
    for x in range(w):
        near_dark = any(dark[y + dy][x + dx]
                        for dy in range(-7, 8) for dx in range(-7, 8)
                        if 0 <= y + dy < h and 0 <= x + dx < w)
        ink[y][x] = 1 if bright[y][x] and near_dark else 0

# The tile fills almost the whole canvas; only the four rounded corners are background.
# Flood-fill those from the image corners so canvas white never counts as car.
outside = [[0] * w for _ in range(h)]
queue = []
for cx, cy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
    if not dark[cy][cx] and not outside[cy][cx]:
        outside[cy][cx] = 1
        queue.append((cx, cy))
while queue:
    x, y = queue.pop()
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx, ny = x + dx, y + dy
        if 0 <= nx < w and 0 <= ny < h and not outside[ny][nx] and not dark[ny][nx]:
            outside[ny][nx] = 1
            queue.append((nx, ny))
for y in range(h):
    for x in range(w):
        if outside[y][x]:
            ink[y][x] = 0

# Close the outline: dilate twice so the car body becomes solid at menu bar size.
for _ in range(2):
    ink = [[max(ink[r + dr][c + dc]
                for dr in (-1, 0, 1) for dc in (-1, 0, 1)
                if 0 <= r + dr < h and 0 <= c + dc < w)
            for c in range(w)] for r in range(h)]

xs = [x for y in range(h) for x in range(w) if ink[y][x]]
ys = [y for y in range(h) for x in range(w) if ink[y][x]]
x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
print("ink bbox", x0, y0, x1, y1, "of", w, h)
side = max(x1 - x0 + 1, y1 - y0 + 1)


def render(size):
    scale = side / size
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    grid = [[0.0] * size for _ in range(size)]
    for row in range(size):
        for col in range(size):
            sx0 = int(cx + (col + 0.5 - size / 2) * scale)
            sx1 = max(sx0 + 1, int(cx + (col + 1.5 - size / 2) * scale))
            sy0 = int(cy + (row + 0.5 - size / 2) * scale)
            sy1 = max(sy0 + 1, int(cy + (row + 1.5 - size / 2) * scale))
            total = count = 0
            for y in range(max(0, sy0), min(h, sy1)):
                for x in range(max(0, sx0), min(w, sx1)):
                    total += ink[y][x]
                    count += 1
            grid[row][col] = total / count if count else 0.0

    out = [[0.0] * size for _ in range(size)]
    for r in range(size):
        for c in range(size):
            total = 0.0
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    total += grid[min(size - 1, max(0, r + dr))][min(size - 1, max(0, c + dc))]
            out[r][c] = total / 9

    filled = [r for r in range(size) for c in range(size) if out[r][c] > 0.03]
    cols_ = [c for r in range(size) for c in range(size) if out[r][c] > 0.03]
    ry0, ry1, rx0, rx1 = min(filled), max(filled), min(cols_), max(cols_)
    pad = 1
    canvas = [[0.0] * size for _ in range(size)]
    for r in range(size):
        for c in range(size):
            sr = r - ry0 + pad
            sc = c - rx0 + pad
            if 0 <= sr < size and 0 <= sc < size:
                canvas[r][c] = out[sr][sc]

    # Menu bar glyphs must read at 16pt: harden the edges and thicken thin parts,
    # otherwise the outline turns into a grey smudge.
    crisp = [[min(1.0, max(0.0, (canvas[r][c] - 0.32) / 0.30)) for c in range(size)]
             for r in range(size)]
    bold = [[max(crisp[min(size - 1, max(0, r + dr))][min(size - 1, max(0, c + dc))]
                 for dr in (-1, 0, 1) for dc in (-1, 0, 1))
             for c in range(size)] for r in range(size)]

    rgba = bytearray()
    for r in range(size):
        for c in range(size):
            rgba += bytes((0, 0, 0, int(bold[r][c] * 255)))
    return rgba


for size, name in ((16, f"{OUT}/MenuBarSupra.png"), (32, f"{OUT}/MenuBarSupra@2x.png")):
    write_png(name, size, size, render(size))
    print("wrote", name)
