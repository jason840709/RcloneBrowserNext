import type { Translate } from './i18n';

type Key = Parameters<Translate>[0];
/**
 * caution: rclone recovers by itself (orange light, folded).
 * action: the user should fix something, the rest of the job continues (red light, folded).
 * urgent: nothing more can transfer until the user acts (red light, explanation shown).
 */
export type ErrorSeverity = 'caution' | 'action' | 'urgent';
export interface ErrorExplanation { severity: ErrorSeverity; title: string; detail: string; shared: boolean }

// rclone and cloud services report errors as raw API text (status codes, JSON
// details). Each rule recognises one common cause and gives a short title, a
// plain explanation and how serious it is; the original text stays available.
// Order matters: the first match wins, so the specific Google quota cases come
// before the generic 403.
const rules: Array<[RegExp, ErrorSeverity, Key, Key]> = [
  [/storageQuotaExceeded|storage quota has been exceeded|insufficient ?storage|quota.*storage|\b507\b/i, 'urgent', 'errCloudFullTitle', 'errCloudFull'],
  [/rateLimitExceeded|userRateLimitExceeded|RATE_LIMIT_EXCEEDED|Quota exceeded|Too Many Requests|\b429\b|TooManyRequests|throttl/i, 'caution', 'errRateLimitTitle', 'errRateLimit'],
  [/no space left on device|not enough space|disk full/i, 'urgent', 'errDiskFullTitle', 'errDiskFull'],
  [/invalid_grant|token (has )?expired|couldn't fetch token|failed to refresh token|unauthori[sz]ed|\b401\b|invalid authentication/i, 'urgent', 'errAuthTitle', 'errAuth'],
  [/permission denied|operation not permitted|access denied|insufficientPermissions|forbidden|\b403\b/i, 'action', 'errPermissionTitle', 'errPermission'],
  [/file name too long|name too long|path too long/i, 'action', 'errNameTooLongTitle', 'errNameTooLong'],
  [/invalid argument|illegal character|invalid (file ?)?name|invalid character/i, 'action', 'errBadNameTitle', 'errBadName'],
  [/directory not found|object not found|no such file|not found|\b404\b/i, 'caution', 'errNotFoundTitle', 'errNotFound'],
  [/hash(es)? differ|checksum|corrupted on transfer|md5 (do not|don't) match/i, 'caution', 'errChecksumTitle', 'errChecksum'],
  [/connection reset|connection refused|i\/o timeout|timeout|timed out|no such host|network is unreachable|unexpected EOF|broken pipe|TLS handshake|dial tcp/i, 'caution', 'errNetworkTitle', 'errNetwork'],
  [/backendError|internalError|internal server error|service unavailable|bad gateway|\b50[0234]\b/i, 'caution', 'errServerTitle', 'errServer'],
];

/** rclone's shared Google Drive project; its quota is shared by every user without an own client_id. */
const sharedGoogleProject = /202264815644|shared Google Drive client_id/;

/** A plain-language explanation of an rclone error, or null when the cause is not recognised. */
export function explainError(message: string | undefined | null, t: Translate): ErrorExplanation | null {
  if (!message) return null;
  for (const [pattern, severity, title, detail] of rules) {
    if (!pattern.test(message)) continue;
    const shared = title === 'errRateLimitTitle' && sharedGoogleProject.test(message);
    return { severity, title: t(title), detail: t(detail), shared };
  }
  return null;
}
