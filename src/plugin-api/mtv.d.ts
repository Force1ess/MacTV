interface MTVMediaItem {
  id: string;
  title: string;
  subtitle: string;
  overview: string;
  source: string;
  poster?: string;
  reference?: string;
  /** Native Music track reference used for local album artwork. No file URLs. */
  artworkReference?: string;
  /** Optional part/episode folder shown as a native detail action. Requires folders capability. */
  collectionReference?: string;
  kind?: 'video' | 'folder' | 'photo' | 'audio';
  url?: string;
}
interface MTVPage { items: MTVMediaItem[]; next?: string; requiresLogin?: boolean }
interface MTVPlayback {
  url: string;
  videoOwner?: string;
  videoOverview?: string;
  quality?: number;
  qualityTitle?: string;
  qualities?: {id: number; title: string; available: boolean; reason?: string}[];
  height?: number;
  bandwidth?: number;
  note?: string;
  expiresAt?: number;
  /** Progressive MP4/MOV; Referer must match manifest.playbackReferer. No Cookie/Authorization. */
  headers?: Partial<Record<'User-Agent' | 'Referer', string>>;
  /** Optional independent MP4 audio. Both addresses use the same reviewed public headers/domain policy. */
  audioURL?: string;
  /** Clear single-track AVC/AAC fragmented MP4 pairs with a complete direct sidx index. */
  transport?: 'indexed-fmp4' | 'original-matroska' | 'original-file';
  /** MTV 59+. Requires continuation + folders + resolve. Stable references only, never media URLs. */
  continuation?: MTVContinuation;
}
interface MTVContinuation {
  currentReference: string;
  collectionReference: string;
  label: string;
  /** Must explicitly return null for the last known part. A next item must have a different reference and no url. */
  next: MTVMediaItem | null;
}
interface MTVPlugin {
  handle(action: string, input: Record<string, string>): MTVPage | MTVPlayback | MTVLogin | MTVContinuation;
}
interface MTVLogin {
  state: 'waiting' | 'scanned' | 'expired' | 'authorized';
  message?: string;
  qrURL?: string;
  token?: string;
  expiresAt?: number;
  displayName?: string;
}
declare const host: {
  /** Native, declared library services; no arbitrary file or shell access. */
  library(service: 'photos' | 'pictures' | 'music' | 'quark-pictures', input?: Record<string, string>): MTVPage;
  // Prototype bridge: bounded synchronous request in a disposable helper process.
  // Returned JSON is unknown until the adapter checks the platform response.
  fetchJSON(url: string, options?: {authenticated?: boolean; captureSession?: boolean; method?: 'GET' | 'POST'; body?: Record<string, unknown>}): unknown;
  readonly sessionAvailable: boolean;
};
