import { useEffect, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";
import { centredCrop, cropBox, cropToPng, imageProblem, imageType, MAX_ZOOM, moveCrop, openImage, pictureUrl, type Crop } from "../lib/picture";

/** A coin's picture as the creator chose it, the way Ascend's launch form takes it: the file it came from, whether it
 * is used as it is or cropped to a square, and the bytes that will be stored. */
export type CoinImage = {
  source: { file: File; img: HTMLImageElement };
  crop: Crop;
  original: boolean;
  bytes: Uint8Array;
  type: string;
};

type Draft = { source: CoinImage["source"]; crop: Crop; original: boolean };

/** The crop window's side, in CSS pixels. */
const VIEW = 280;
const msg = (e: unknown) => (e instanceof Error ? e.message : String(e));
const size = (n: number) => (n >= 1_000_000 ? `${(n / 1024 / 1024).toFixed(1)} MB` : `${Math.max(1, Math.round(n / 1024))} KB`);

/** The coin picture picker. It starts empty, and the picture is optional. A chosen file opens the editor, where the
 * creator keeps a square crop (saved as a PNG of up to 512 pixels) or the original file, as on Ascend. */
export function ImagePicker({ value, onChange }: { value?: CoinImage; onChange: (v?: CoinImage) => void }) {
  const input = useRef<HTMLInputElement>(null);
  const [draft, setDraft] = useState<Draft>();
  const [error, setError] = useState<string>();
  const [opening, setOpening] = useState(false);
  const preview = useMemo(() => pictureUrl(value?.bytes), [value]);

  const choose = async (file?: File) => {
    if (!file) return;
    setError(undefined);
    const problem = await imageProblem(file);
    if (problem) return setError(problem);
    setOpening(true);
    try {
      const img = await openImage(file);
      setDraft({ source: { file, img }, crop: centredCrop(img.naturalWidth, img.naturalHeight), original: false });
    } catch (e) {
      setError(msg(e));
    } finally {
      setOpening(false);
    }
  };

  return (
    <div className="picture-pick">
      {preview ? <img className="coin-art" src={preview} alt="The coin's picture" /> : <div className="coin-art coin-art-empty" aria-hidden="true" />}
      <div>
        <div className="input-row wrap">
          <button type="button" className="btn btn-ghost" disabled={opening} onClick={() => input.current?.click()}>
            {opening ? "Opening image…" : value ? "Change image" : "Choose image"}
          </button>
          {value && (
            <button type="button" className="btn btn-ghost" onClick={() => setDraft({ source: value.source, crop: value.crop, original: value.original })}>
              Adjust crop
            </button>
          )}
          {value && (
            <button type="button" className="btn btn-ghost" onClick={() => onChange(undefined)}>
              Remove image
            </button>
          )}
        </div>
        <p className={`small field-help ${error ? "warn" : "muted"}`} role={error ? "alert" : undefined}>
          {error ?? (value ? `${value.original ? "Original image selected" : "Square crop selected"} · ${size(value.bytes.length)}` : "PNG, JPG, WebP or GIF · under 2 MB")}
        </p>
      </div>
      <input
        ref={input}
        type="file"
        hidden
        accept="image/png,image/jpeg,image/gif,image/webp"
        onChange={(e) => {
          void choose(e.target.files?.[0]);
          e.target.value = "";
        }}
      />
      {draft && (
        <ImageEditor
          draft={draft}
          onDraft={setDraft}
          onCancel={() => setDraft(undefined)}
          onUse={(v) => {
            onChange(v);
            setDraft(undefined);
          }}
        />
      )}
    </div>
  );
}

/** The editor, in a dialog: square crop or original image, drag or arrow keys to place the crop, and zoom. */
function ImageEditor({ draft, onDraft, onCancel, onUse }: { draft: Draft; onDraft: (d: Draft) => void; onCancel: () => void; onUse: (v: CoinImage) => void }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const drag = useRef<{ x: number; y: number; id: number }>(undefined);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();
  const { img } = draft.source;
  const w = img.naturalWidth;
  const h = img.naturalHeight;
  const box = cropBox(w, h, draft.crop);
  const scale = VIEW / box.size;

  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
  }, []);

  const move = (dx: number, dy: number) => onDraft({ ...draft, crop: moveCrop(w, h, draft.crop, dx, dy) });
  const onPointerDown = (e: PointerEvent<HTMLDivElement>) => {
    if (draft.original || saving || (e.pointerType === "mouse" && e.button !== 0)) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    drag.current = { x: e.clientX, y: e.clientY, id: e.pointerId };
  };
  const onPointerMove = (e: PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d || d.id !== e.pointerId) return;
    move(-(e.clientX - d.x) / scale, -(e.clientY - d.y) / scale);
    drag.current = { ...d, x: e.clientX, y: e.clientY };
  };
  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    if (draft.original) return;
    const step = box.size * (e.shiftKey ? 0.1 : 0.02);
    const keys: Record<string, [number, number]> = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] };
    const k = keys[e.key];
    if (!k) return;
    e.preventDefault();
    move(k[0], k[1]);
  };

  const use = async () => {
    setSaving(true);
    setError(undefined);
    try {
      const bytes = draft.original ? new Uint8Array(await draft.source.file.arrayBuffer()) : await cropToPng(img, draft.crop);
      const type = imageType(bytes);
      if (!type) throw new Error("The image must be a PNG, JPEG, GIF or WebP.");
      onUse({ ...draft, bytes, type });
    } catch (e) {
      setError(msg(e));
      setSaving(false);
    }
  };

  return (
    <dialog
      ref={dialog}
      className="image-dialog"
      aria-labelledby="image-dialog-title"
      onCancel={(e) => {
        e.preventDefault();
        if (!saving) onCancel();
      }}
    >
      <div className="image-dialog-head">
        <h3 id="image-dialog-title">Token image</h3>
        <button type="button" className="btn btn-ghost btn-icon" aria-label="Close" disabled={saving} onClick={onCancel}>
          ✕
        </button>
      </div>
      <div className="image-format" role="group" aria-label="Image format">
        {(
          [
            [false, "Square crop"],
            [true, "Original image"],
          ] as const
        ).map(([original, label]) => (
          <button
            key={label}
            type="button"
            aria-pressed={draft.original === original}
            disabled={saving}
            onClick={() => onDraft({ ...draft, original })}
          >
            {label}
          </button>
        ))}
      </div>
      <div
        className={`image-viewport${draft.original ? " is-original" : ""}`}
        style={{ width: VIEW, height: VIEW }}
        role="group"
        tabIndex={draft.original || saving ? -1 : 0}
        aria-label="Image crop position"
        aria-describedby="image-dialog-help"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={() => (drag.current = undefined)}
        onPointerCancel={() => (drag.current = undefined)}
        onKeyDown={onKeyDown}
      >
        {draft.original ? (
          <img src={img.src} alt="Artwork preview" draggable={false} />
        ) : (
          <img
            src={img.src}
            alt="Artwork crop preview"
            draggable={false}
            style={{ position: "absolute", left: -box.x * scale, top: -box.y * scale, width: w * scale, height: h * scale, maxWidth: "none" }}
          />
        )}
      </div>
      <p id="image-dialog-help" className="muted small">
        {draft.original
          ? `The file is used as it is (${size(draft.source.file.size)}), so a GIF keeps moving.`
          : "Drag to reposition, or use the arrow keys. Crops save as still images."}
      </p>
      {!draft.original && (
        <div className="image-zoom">
          <label className="field-label" htmlFor="image-zoom">
            Zoom
          </label>
          <input
            id="image-zoom"
            type="range"
            min="1"
            max={String(MAX_ZOOM)}
            step="0.01"
            value={draft.crop.zoom}
            disabled={saving}
            onChange={(e) => onDraft({ ...draft, crop: moveCrop(w, h, { ...draft.crop, zoom: Number(e.target.value) }, 0, 0) })}
          />
          <button type="button" className="btn btn-ghost" disabled={saving} onClick={() => onDraft({ ...draft, crop: centredCrop(w, h) })}>
            Reset
          </button>
        </div>
      )}
      {error && (
        <p className="warn small" role="alert">
          {error}
        </p>
      )}
      <div className="input-row">
        <button type="button" className="btn btn-ghost" disabled={saving} onClick={onCancel}>
          Cancel
        </button>
        <button type="button" className="btn" disabled={saving} aria-busy={saving} onClick={() => void use()}>
          {saving ? "Saving…" : "Use image"}
        </button>
      </div>
    </dialog>
  );
}
