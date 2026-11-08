import { hexToBytes, type Hex } from "viem";

/** A coin picture follows Ascend's own launch form, so a picture that works there works here: a PNG, JPEG, GIF or
 * WebP file under 2 MB, either as it is or cropped to a square, which is saved as a PNG of at most 512 pixels. */
export const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
export const CROP_MAX = 512;
export const MAX_ZOOM = 3;

/** The picture's format from its first bytes. Anything else, SVG and HTML included, is undefined and never shown. */
export function imageType(b: Uint8Array): string | undefined {
  const at = (i: number, s: string) => b.length >= i + s.length && [...s].every((c, j) => b[i + j] === c.charCodeAt(0));
  if (at(0, "\x89PNG")) return "image/png";
  if (at(0, "\xff\xd8\xff")) return "image/jpeg";
  if (at(0, "GIF87a") || at(0, "GIF89a")) return "image/gif";
  if (at(0, "RIFF") && at(8, "WEBP")) return "image/webp";
  return undefined;
}

/** Why a file can't be a coin's picture, in Ascend's words, or undefined when it can. */
export async function imageProblem(file: Blob): Promise<string | undefined> {
  if (file.size > MAX_IMAGE_BYTES) return "The image must be under 2 MB.";
  const head = new Uint8Array(await file.slice(0, 12).arrayBuffer());
  return imageType(head) ? undefined : "The image must be a PNG, JPEG, GIF or WebP.";
}

/** A square crop: its centre in the picture's own pixels, and how far it is zoomed in (1 = the largest square). */
export type Crop = { x: number; y: number; zoom: number };

export const centredCrop = (width: number, height: number): Crop => ({ x: width / 2, y: height / 2, zoom: 1 });

/** The square a crop covers, kept inside the picture. */
export function cropBox(width: number, height: number, c: Crop): { x: number; y: number; size: number } {
  const size = Math.min(width, height) / Math.max(1, Math.min(MAX_ZOOM, c.zoom));
  return {
    x: Math.max(0, Math.min(width - size, c.x - size / 2)),
    y: Math.max(0, Math.min(height - size, c.y - size / 2)),
    size,
  };
}

/** A crop moved by (dx, dy) picture pixels, with its centre kept where the square still fits. */
export function moveCrop(width: number, height: number, c: Crop, dx: number, dy: number): Crop {
  const { size } = cropBox(width, height, c);
  const clamp = (v: number, max: number) => Math.max(size / 2, Math.min(max - size / 2, v));
  return { ...c, x: clamp(c.x + dx, width), y: clamp(c.y + dy, height) };
}

/** Opens a picture file for drawing. */
export async function openImage(file: Blob): Promise<HTMLImageElement> {
  const url = URL.createObjectURL(file);
  const img = new Image();
  img.src = url;
  try {
    await img.decode();
  } catch {
    URL.revokeObjectURL(url);
    throw new Error("This image could not be opened. Try another PNG, JPG, WebP or GIF.");
  }
  return img;
}

/** The square a crop covers, drawn at up to 512 pixels and saved as a PNG (a still image, as on Ascend). */
export async function cropToPng(img: HTMLImageElement, c: Crop): Promise<Uint8Array> {
  const box = cropBox(img.naturalWidth, img.naturalHeight, c);
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = Math.min(CROP_MAX, Math.max(1, Math.round(box.size)));
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("Image editing is unavailable in this browser. Choose Original image to continue.");
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(img, box.x, box.y, box.size, box.size, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise<Blob | null>((done) => canvas.toBlob(done, "image/png"));
  if (!blob) throw new Error("Could not save the crop. Try again or choose Original image.");
  const out = new Uint8Array(await blob.arrayBuffer());
  if (out.length > MAX_IMAGE_BYTES) throw new Error("The cropped image is over 2 MB. Zoom in, or choose Original image.");
  return out;
}

/** A data: URL for picture bytes, or undefined when they aren't a picture the site shows. */
export function pictureUrl(data: Hex | Uint8Array | undefined): string | undefined {
  if (!data) return undefined;
  const b = typeof data === "string" ? hexToBytes(data) : data;
  const type = imageType(b);
  if (!type) return undefined;
  let s = "";
  for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  return `data:${type};base64,${btoa(s)}`;
}
