import { hexToBytes, type Hex } from "viem";

/** AscendV5Launcher.MAX_IMAGE: the picture is stored as a small contract's code, which holds at most 24,576 bytes. */
export const MAX_PICTURE = 24_000;
/** Pictures bigger than this aren't even opened (a 20 MB photo is already far more than a coin picture needs). */
const MAX_FILE = 20_000_000;
const SIDES = [256, 192, 128];
const QUALITIES = [0.9, 0.8, 0.7, 0.6, 0.5, 0.4];

/** The picture's format from its first bytes, for the formats the site shows. Anything else, SVG and HTML included,
 * is undefined and never shown: the bytes on chain are whatever the coin's steward sent. */
export function pictureType(b: Uint8Array): string | undefined {
  const at = (i: number, s: string) => b.length >= i + s.length && [...s].every((c, j) => b[i + j] === c.charCodeAt(0));
  if (at(0, "RIFF") && at(8, "WEBP")) return "image/webp";
  if (at(0, "\x89PNG\r\n\x1a\n")) return "image/png";
  if (at(0, "\xff\xd8\xff")) return "image/jpeg";
  if (at(0, "GIF87a") || at(0, "GIF89a")) return "image/gif";
  return undefined;
}

/** A data: URL for a picture's bytes, or undefined when they aren't a picture the site shows. */
export function pictureUrl(data: Hex | Uint8Array | undefined): string | undefined {
  if (!data) return undefined;
  const b = typeof data === "string" ? hexToBytes(data) : data;
  const type = pictureType(b);
  if (!type) return undefined;
  let s = "";
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return `data:${type};base64,${btoa(s)}`;
}

/** A picture file made small enough to store on chain. A file already under the limit is kept as it is (so an
 * animated GIF stays animated); a bigger one is cropped to a centred square and redrawn at 256 pixels as WebP (JPEG
 * where the browser can't write WebP), at lower quality and then smaller sizes until it fits. */
export async function shrinkPicture(file: File): Promise<Uint8Array> {
  if (file.size > MAX_FILE) throw new Error("That file is over 20 MB. Pick a smaller picture.");
  const raw = new Uint8Array(await file.arrayBuffer());
  const type = pictureType(raw);
  if (!type) throw new Error("Pick a PNG, JPEG, WebP or GIF picture.");
  if (raw.length <= MAX_PICTURE) return raw;
  let bmp: ImageBitmap;
  try {
    bmp = await createImageBitmap(new Blob([raw], { type }));
  } catch {
    throw new Error("This browser couldn't open that picture. Try another file.");
  }
  try {
    const crop = Math.min(bmp.width, bmp.height);
    const sx = (bmp.width - crop) / 2;
    const sy = (bmp.height - crop) / 2;
    for (const side of SIDES) {
      const canvas = document.createElement("canvas");
      canvas.width = canvas.height = side;
      const ctx = canvas.getContext("2d");
      if (!ctx) break;
      ctx.imageSmoothingQuality = "high";
      for (const format of ["image/webp", "image/jpeg"]) {
        ctx.clearRect(0, 0, side, side);
        // JPEG has no transparency: put see-through parts on black, like the site's background
        if (format === "image/jpeg") {
          ctx.fillStyle = "#000";
          ctx.fillRect(0, 0, side, side);
        }
        ctx.drawImage(bmp, sx, sy, crop, crop, 0, 0, side, side);
        for (const q of QUALITIES) {
          const blob = await new Promise<Blob | null>((done) => canvas.toBlob(done, format, q));
          // a browser that can't write the format hands back a PNG instead: move on to the next format
          if (!blob || blob.type !== format) break;
          if (blob.size <= MAX_PICTURE) return new Uint8Array(await blob.arrayBuffer());
        }
      }
    }
  } finally {
    bmp.close();
  }
  throw new Error("That picture couldn't be made small enough. Try a simpler one.");
}
