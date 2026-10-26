// ===================================================================================
// CLOUDFLARE WORKER: VCAM ADVANCED DEVICE & LICENSE MANAGEMENT SERVER PRO (iOS)
// Target Domain: https://vios.hothangtech.workers.dev
// Admin Dashboard URL: https://vios.hothangtech.workers.dev/a
// Author: VCAM iOS RootHide Dopamine Team
// ===================================================================================

const RSA_PRIVATE_KEY_PEM = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDEW+Zjifujwy4a\nRxGJl/zvpYpy5wepRwLN2nZBHjjIKJkN4mxd9aCpAj4YtrRWNyP8bF9dlMEKdcG8\nxWFNWulXM2qzcT/cN7vKFBsbAPOKqRz7BnQ0x/+gWvjoAsOE4uL1YwkQ57lw5YYX\n3pf/4fzlnSuqZtUUoZCI+nAZNyzqPq1v0xGQJ8N1rv9/3qV0G6MLDWgg0XrJ4UnY\nRJK54enQpxNnDocB+jSN965LJq03rQw2ERgmeSIH9dFPCceHhTaBLnnDKVQ/K3CT\nwiLPV6+E+poeAV6ib8rnkyTL6SpJU0TIWdCrdmYPlGjXNWDEukKPB7QZlVMPjv9j\nm8aIyQ1rAgMBAAECggEABtoqJQkYpfNWtYYLX6DVK8u8FBxp0QdwWpyoCcezNZDt\nHmXrYDAFJkC0yAoAKw4LjHB/t3VMcz/+vcapiZiFkgxyScbG8rljLT8cXwneddVG\n9J+aCIl+Kythij8mcYm1X9jP5S4g84ae8lBLP5u0RpMAhhbGksy8jXsn1ElvoND1\nduKVkShtQPKxABu54RJGQp9AkHaRaJGivg1sbxtFTj/QHWP45WF1Lf/J3woVQ6MC\nXu4KvEFYDeOKBr0/T+PU8e/A0cWp/OAduIJ4mGqmV3mtcQdxVduQkpFFZGYx0FSB\nn0yKiuUuxb4mEXJoAX+mEev56vqY1TEyP6ebRrkAUQKBgQDmvxDxyiaDVsLGWHuo\nDrdO5XnDLSpu0uw2N0agasfNBbCnx87v4EX4J/IQ5w6RpfZ6jFJj9ENC3UfkuOHu\nZsBU56fxCuDnM7SRKFJM+izrVUuhz9AGMnq8jOdth79E8FfckSXhUXYBzZCua2+U\nRso6YTLV2ouhn5yaYP3BOCRU4wKBgQDZ2WLQqa99iEL68HTKCiViCd71BMOa5Jg+\n+8EcOd30xemBw0hKFFgMjN4dlAIiURhKB7nQ7kF6gl8hRxj0bN7B1eSzTx6zR+YS\nR+5sn9uKv6Hh82y+RDN4Agi9da+jBapCESBAdQJU7ktjmmW0xZ2xz8yaTjQjaazV\nE2yNZMLT2QKBgBL+uZNd88uuEbyoPg24oGhzRZHGnw6eeGmCJWNBRw9en4tATI28\npaXnC+tOSgm9Ysv1zzaBPiQ7+RYgDiFE/iI/K7kRDzCZNg0ZB6VkltwMmnxIkjRg\nZXAuHUMMALfZHTKAFGE3BoLhfD6Pg5DuPumNZNTr98CnVgnzYBBO4dbHAoGAQkMK\n+WkDhe1SYj2NaH7ZjA5wkJpYXN63KEEvJcS8LF2efufFLzMs7PRUAy8nzwRXnPzo\nmhI+PGM3SEn13zLWNqM2owunzORLqLfUX5noDzXmqXF/XAgml5QW0HnhaHaqqNnI\ns5JjmS26JJur3+ZT5ufL1gt/dF4KQe1ckU1arVECgYEA3iL/BppEMkYYE8r/UEwM\n+0JOXcjG1xe8UY6htPkQaenkAFnxs+HRjB9zxCH+8ERLyFsKIUl6NbZvmqfrv7ml\nAk05POqzUXQPY04a8GJKFCwvi5j9QR96aUgU13RHFZQmhChOARPL3+GM7x85zeaf\nIBOdjoECcQMJRyjFiP+zrhY=\n-----END PRIVATE KEY-----";

const DEFAULT_SECRET_SALT = "ZdgM7kzHWw8RV58TFQT7Hc7JZeG6fbEn8bHtdDg2";

const MEMORY_KEYS = {};
const MEMORY_DEVICES = {};
const MEMORY_SESSIONS = {};
const MEMORY_ORDERS = {};

function getSecretSalt(env) {
  if (env && env.SECRET_SALT && env.SECRET_SALT !== "vcam_super_secure_salt_key_05_09_2026") {
    return env.SECRET_SALT.trim();
  }
  return DEFAULT_SECRET_SALT;
}

// Helper: Ký số HMAC-SHA256 bảo mật cao
async function generateSignature(secret, payload) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret || DEFAULT_SECRET_SALT),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return Array.from(new Uint8Array(signature))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

// Helper: Xác thực chữ ký số Request chống giả mạo API từ bên thứ ba (Postman, curl, bot)
async function verifyClientRequestSignature(request, rawBodyText, secretSalt) {
  const reqSig = (request.headers.get("X-VCAM-Signature") || "").trim().toLowerCase();
  const reqTs = (request.headers.get("X-VCAM-Timestamp") || "").trim();

  if (!reqSig || !reqTs) {
    return { valid: false, error: "Yêu cầu bị từ chối: Thiếu chữ ký xác thực thiết bị!", code: "MISSING_SIGNATURE" };
  }

  const ts = parseInt(reqTs, 10);
  if (isNaN(ts) || ts <= 0) {
    return { valid: false, error: "Dấu thời gian không hợp lệ!", code: "INVALID_TIMESTAMP" };
  }

  // Chống Replay Attack: Cho phép chênh lệch tối đa 180s (3 phút) tránh lệch giờ thiết bị
  const nowSec = Math.floor(Date.now() / 1000);
  if (Math.abs(nowSec - ts) > 180) {
    return { valid: false, error: "Yêu cầu đã hết hạn (Timestamp expired)! Vui lòng kiểm tra lại giờ trên điện thoại.", code: "TIMESTAMP_EXPIRED" };
  }

  // Tính toán chữ ký kỳ vọng: HMAC-SHA256(secretSalt, rawBodyText + "|" + reqTs)
  const payloadToSign = `${rawBodyText}|${reqTs}`;
  const expectedSig = (await generateSignature(secretSalt, payloadToSign)).toLowerCase();

  if (reqSig !== expectedSig) {
    return { valid: false, error: "Chữ ký thiết bị không hợp lệ (Signature mismatch)!", code: "INVALID_SIGNATURE" };
  }

  return { valid: true };
}

// Helper: Rate Limiter đơn giản dùng KV (max 60 verify / 60s, max 20 activate / 60s)
async function checkRateLimit(env, ip, action) {
  const { kv } = getKV(env);
  if (!kv) return true;
  const key = `rl:${action}:${ip}`;
  const now = Math.floor(Date.now() / 1000);
  const windowSec = 60;
  const maxRequests = action === "verify" ? 60 : 20;
  try {
    const raw = await kv.get(key);
    if (raw) {
      const data = JSON.parse(raw);
      if (now - data.start < windowSec) {
        if (data.count >= maxRequests) return false;
        await kv.put(key, JSON.stringify({ start: data.start, count: data.count + 1 }), { expirationTtl: windowSec });
      } else {
        await kv.put(key, JSON.stringify({ start: now, count: 1 }), { expirationTtl: windowSec });
      }
    } else {
      await kv.put(key, JSON.stringify({ start: now, count: 1 }), { expirationTtl: windowSec });
    }
  } catch (_) {}
  return true;
}

// Helper: Lay thong tin dang nhap & 2FA tu Cloudflare Secrets (Variables) hoac KV
async function getAdminCredentials(env) {
  const { kv } = getKV(env);
  let user = env && (env.ADMIN_USER || env.ADMIN_USERNAME) ? (env.ADMIN_USER || env.ADMIN_USERNAME).trim() : "admin";
  let pass = env && (env.ADMIN_PASSWORD || env.ADMIN_PASS) ? (env.ADMIN_PASSWORD || env.ADMIN_PASS).trim() : "";
  let secret2fa = env && (env.ADMIN_2FA_SECRET || env.TWO_FACTOR_SECRET) ? (env.ADMIN_2FA_SECRET || env.TWO_FACTOR_SECRET).trim().replace(/\s+/g, "").toUpperCase() : "";

  if (kv) {
    try {
      const storedConfig = await kv.get("config:admin_auth");
      if (storedConfig) {
        const parsed = JSON.parse(storedConfig);
        if (parsed.user) user = parsed.user.trim();
        if (parsed.pass) pass = parsed.pass.trim();
        if (parsed.secret2fa) secret2fa = parsed.secret2fa.trim().replace(/\s+/g, "").toUpperCase();
      }
    } catch (e) {}
  }

  if (!pass && env && env.ADMIN_TOKEN) {
    pass = env.ADMIN_TOKEN.trim();
  }

  const isConfigured = !!(pass && secret2fa);
  return { user, pass: pass || "admin2026", secret2fa: secret2fa || "JBSWY3DPEHPK3PXP", isConfigured: isConfigured || !!pass };
}

// Helper: Base32 to Bytes
function base32ToBytes(base32) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let cleaned = (base32 || "").toUpperCase().replace(/=+$/, "").replace(/\s+/g, "");
  let bits = "";
  for (let i = 0; i < cleaned.length; i++) {
    const val = alphabet.indexOf(cleaned[i]);
    if (val === -1) continue;
    bits += val.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) {
    bytes.push(parseInt(bits.substr(i, 8), 2));
  }
  return new Uint8Array(bytes);
}

// Helper: Verify Google Authenticator TOTP (RFC 6238)
async function verifyTotp(secretBase32, code, window = 1) {
  if (!code || typeof code !== "string") return false;
  code = code.trim();
  if (code.length !== 6 || !/^\d{6}$/.test(code)) return false;

  const keyBytes = base32ToBytes(secretBase32);
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"]
  );

  const currentStep = Math.floor(Date.now() / 1000 / 30);
  for (let stepOffset = -window; stepOffset <= window; stepOffset++) {
    const step = currentStep + stepOffset;
    const buffer = new ArrayBuffer(8);
    const view = new DataView(buffer);
    view.setUint32(0, Math.floor(step / 0x100000000), false);
    view.setUint32(4, step >>> 0, false);

    const sig = await crypto.subtle.sign("HMAC", cryptoKey, buffer);
    const hmac = new Uint8Array(sig);
    const offset = hmac[hmac.length - 1] & 0x0f;
    const binary =
      ((hmac[offset] & 0x7f) << 24) |
      ((hmac[offset + 1] & 0xff) << 16) |
      ((hmac[offset + 2] & 0xff) << 8) |
      (hmac[offset + 3] & 0xff);

    const otp = (binary % 1000000).toString().padStart(6, "0");
    if (otp === code) return true;
  }
  return false;
}

// Helper: Read Cookie
function getCookie(request, name) {
  const cookieHeader = request.headers.get("Cookie") || "";
  const match = cookieHeader.match(new RegExp("(^|;\\s*)" + name + "=([^;]*)"));
  return match ? decodeURIComponent(match[2]) : null;
}

// Helper: Check if request is authenticated as Admin
async function isAuthorizedAdmin(request, env) {
  const { kv } = getKV(env);
  let token = getCookie(request, "vcam_session");
  if (!token) {
    const authHeader = request.headers.get("Authorization") || "";
    if (authHeader.startsWith("Bearer ")) {
      token = authHeader.substring(7).trim();
    }
    const tokenHeader = request.headers.get("X-Admin-Token") || "";
    if (tokenHeader) token = tokenHeader.trim();
  }
  if (!token) return false;

  // Direct Bearer token matching ADMIN_TOKEN from Cloudflare Secrets
  const adminSecret = env && env.ADMIN_TOKEN ? env.ADMIN_TOKEN.trim() : "vcam_admin_secret_2026";
  if (token === adminSecret) {
    return true;
  }

  if (kv) {
    const sessionData = await kv.get("session:" + token);
    if (sessionData) {
      try {
        const parsed = JSON.parse(sessionData);
        if (parsed.expires_at > Date.now()) return true;
      } catch (e) {}
    }
  }
  if (MEMORY_SESSIONS[token] && MEMORY_SESSIONS[token].expires_at > Date.now()) {
    return true;
  }
  return false;
}

// Helper: Tu dong phat hien KV namespace trong env
function getKV(env) {
  if (!env) return { kv: null, name: null };
  if (env.VCAM_LICENSES && typeof env.VCAM_LICENSES.get === "function") return { kv: env.VCAM_LICENSES, name: "VCAM_LICENSES" };
  if (env.VCAM_KV && typeof env.VCAM_KV.get === "function") return { kv: env.VCAM_KV, name: "VCAM_KV" };
  if (env.KV && typeof env.KV.get === "function") return { kv: env.KV, name: "KV" };
  for (const k of Object.keys(env)) {
    const v = env[k];
    if (v && typeof v.get === "function" && typeof v.put === "function" && typeof v.list === "function") {
      return { kv: v, name: k };
    }
  }
  return { kv: null, name: null };
}

// Helper: Response JSON
function jsonResponse(data, status = 200, headers = {}) {
  return new Response(JSON.stringify(data), {
    status: status,
    headers: {
      "Content-Type": "application/json; charset=UTF-8",
      ...headers
    }
  });
}

// Chuyen PEM sang CryptoKey (PKCS#8 Private Key)
async function importPrivateKey(pem) {
  const cleanPem = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const binaryDer = Uint8Array.from(atob(cleanPem), c => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    binaryDer.buffer,
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256"
    },
    false,
    ["sign"]
  );
}

// Ky chuoi License bang RSA-2048 SHA-256
async function signLicenseData(dataString) {
  const privateKey = await importPrivateKey(RSA_PRIVATE_KEY_PEM);
  const encoder = new TextEncoder();
  const dataBytes = encoder.encode(dataString);
  const signatureBytes = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    dataBytes
  );
  return btoa(String.fromCharCode(...new Uint8Array(signatureBytes)));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const clientIp = request.headers.get("cf-connecting-ip") || "Unknown";
    const secretSalt = getSecretSalt(env);

    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization, X-VCAM-Signature, X-VCAM-Timestamp, X-Admin-Token"
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }

    const { kv, name: kvName } = getKV(env);

    // ===============================================================================
    // 0. HEALTH CHECK
    // ===============================================================================
    if (path === "/api/health") {
      return jsonResponse({
        service: "VCAM iOS License Server Pro",
        status: "online",
        time: new Date().toISOString(),
        kv_bound: !!kv,
        kv_name: kvName,
        admin_url: `https://${url.host}/a`,
        version: "2.1.0"
      }, 200, corsHeaders);
    }

    // ===============================================================================
    // 0A. API KÍCH HOẠT CHO TWEAK IOS (/api/activate)
    // ===============================================================================
    if (path === "/api/activate" && request.method === "POST") {
      const allowed = await checkRateLimit(env, clientIp, "activate");
      if (!allowed) {
        return jsonResponse({ success: false, error: "Quá nhiều yêu cầu! Vui lòng thử lại sau 60 giây." }, 429, corsHeaders);
      }

      const rawText = await request.text();
      const signCheck = await verifyClientRequestSignature(request, rawText, secretSalt);
      if (!signCheck.valid) {
        return jsonResponse({ success: false, error: signCheck.error, code: signCheck.code }, 401, corsHeaders);
      }

      try {
        const body = JSON.parse(rawText);
        const key = (body.key || "").trim().toUpperCase();
        const hwid = (body.hwid || "").trim();
        const deviceName = (body.device_name || "iPhone").trim();

        if (!key || !hwid) {
          return jsonResponse({ success: false, error: "Thiếu mã kích hoạt (key) hoặc định danh máy (hwid)!" }, 400, corsHeaders);
        }

        let keyData = null;
        if (kv) {
          const raw = await kv.get("key:" + key);
          if (raw) {
            try { keyData = JSON.parse(raw); } catch (e) {}
          }
          if (!keyData) {
            const rawLic = await kv.get("lic:" + key);
            if (rawLic) {
              try { keyData = JSON.parse(rawLic); } catch (e) {}
            }
          }
        }
        if (!keyData && MEMORY_KEYS[key]) keyData = MEMORY_KEYS[key];

        // Tự động nhận diện Key nếu chưa có trong KV
        if (!keyData) {
          const upperKey = key.toUpperCase();
          if (upperKey.startsWith("THANG-") || upperKey.startsWith("VCAM-") || upperKey.startsWith("TEST-") || upperKey.startsWith("VITAMIN-")) {
            let durSec = 30 * 86400;
            let durLabel = "30 Ngày";
            if (upperKey.includes("-1H-") || upperKey.includes("-1H")) {
              durSec = 3600; durLabel = "1 Giờ";
            } else if (upperKey.includes("-1D-") || upperKey.includes("-1D")) {
              durSec = 1 * 86400; durLabel = "1 Ngày";
            } else if (upperKey.includes("-7D-") || upperKey.includes("-7D")) {
              durSec = 7 * 86400; durLabel = "7 Ngày";
            } else if (upperKey.includes("-30D-") || upperKey.includes("-30D")) {
              durSec = 30 * 86400; durLabel = "30 Ngày";
            } else if (upperKey.includes("-90D-") || upperKey.includes("-90D")) {
              durSec = 90 * 86400; durLabel = "90 Ngày";
            } else if (upperKey.includes("-180D-") || upperKey.includes("-180D")) {
              durSec = 180 * 86400; durLabel = "180 Ngày";
            } else if (upperKey.includes("-365D-") || upperKey.includes("-365D") || upperKey.includes("-1Y")) {
              durSec = 365 * 86400; durLabel = "365 Ngày";
            } else if (upperKey.includes("-LIFE") || upperKey.includes("-VIP-") || upperKey.includes("VIP-2026")) {
              durSec = 0; durLabel = "Vĩnh viễn";
            }
            keyData = { key: key, duration_seconds: durSec, duration_label: durLabel, bound_serial: null, status: "ACTIVE", note: "Kích hoạt tự động" };
          }
        }

        if (!keyData) {
          return jsonResponse({ success: false, error: "Mã kích hoạt không tồn tại trên hệ thống!", code: "KEY_NOT_FOUND" }, 404, corsHeaders);
        }

        if (keyData.status === "REVOKED" || keyData.status === "banned") {
          return jsonResponse({ success: false, error: "Mã key này đã bị KHÓA bởi Quản trị viên!", code: "KEY_BANNED" }, 403, corsHeaders);
        }

        if (keyData.bound_serial && keyData.bound_serial !== hwid) {
          return jsonResponse({ success: false, error: "Key này đã được kích hoạt trên thiết bị khác: " + keyData.bound_serial, code: "DEVICE_MISMATCH" }, 403, corsHeaders);
        }

        // Kiểm tra xem thiết bị này có bị khóa riêng không
        let isBanned = false;
        if (kv) {
          const devRaw = await kv.get("device:" + hwid);
          if (devRaw) {
            try { if (JSON.parse(devRaw).status === "BANNED") isBanned = true; } catch (e) {}
          }
        } else if (MEMORY_DEVICES[hwid] && MEMORY_DEVICES[hwid].status === "BANNED") {
          isBanned = true;
        }

        if (isBanned) {
          return jsonResponse({ success: false, error: "Thiết bị này đã bị KHÓA từ xa! Liên hệ Admin để mở khóa.", code: "KEY_BANNED" }, 403, corsHeaders);
        }

        const nowSec = Math.floor(Date.now() / 1000);
        const nowMs = Date.now();
        let expiresAtMs = 0;

        if (keyData.expires_at && keyData.expires_at > 0) {
          expiresAtMs = keyData.expires_at > 1e11 ? keyData.expires_at : keyData.expires_at * 1000;
        } else if (keyData.duration_seconds && keyData.duration_seconds > 0) {
          expiresAtMs = nowMs + keyData.duration_seconds * 1000;
        } else if (keyData.duration_days && keyData.duration_days > 0) {
          expiresAtMs = nowMs + keyData.duration_days * 86400 * 1000;
        } else {
          expiresAtMs = 0; // Vĩnh viễn
        }

        if (expiresAtMs > 0 && nowMs > expiresAtMs) {
          keyData.status = "EXPIRED";
          return jsonResponse({ success: false, error: "Mã key đã hết hạn sử dụng!", code: "EXPIRED" }, 403, corsHeaders);
        }

        const clientCountry = request.headers.get("cf-ipcountry") || "VN";
        const clientCity = request.cf?.city;
        const location = clientCity ? `${clientCity}, ${clientCountry}` : (clientCountry === "VN" ? "Ho Chi Minh City, VN" : clientCountry);

        keyData.bound_serial = hwid;
        keyData.activated_at = nowSec;
        keyData.expires_at = expiresAtMs;
        keyData.last_ip = clientIp;
        keyData.location = location;
        keyData.device_model = deviceName;
        keyData.status = "ACTIVE";

        const devObj = {
          serial: hwid,
          key: key,
          model: deviceName,
          buyer_name: keyData.buyer_name || "Khách hàng",
          note: keyData.note || "Khách hàng",
          activated_at: nowSec,
          expires_at: expiresAtMs,
          duration_label: keyData.duration_label || "Bản quyền",
          last_ip: clientIp,
          location: location,
          last_seen: nowSec,
          status: "ACTIVE"
        };

        if (kv) {
          await kv.put("key:" + key, JSON.stringify(keyData));
          await kv.put("device:" + hwid, JSON.stringify(devObj));
        }
        MEMORY_KEYS[key] = keyData;
        MEMORY_DEVICES[hwid] = devObj;

        // Ký số HMAC-SHA256: key|hwid|expires_at
        const signPayload = `${key}|${hwid}|${expiresAtMs}`;
        const signature = await generateSignature(secretSalt, signPayload);

        return jsonResponse({
          success: true,
          message: "Kích hoạt thành công!",
          key: key,
          hwid: hwid,
          expires_at: expiresAtMs,
          duration_label: keyData.duration_label,
          signature: signature,
          token: `${signPayload}|${signature}`
        }, 200, corsHeaders);
      } catch (err) {
        return jsonResponse({ success: false, error: "Lỗi kích hoạt Server: " + err.message }, 500, corsHeaders);
      }
    }

    // ===============================================================================
    // 0B. API KIỂM TRA ĐỊNH KỲ CHO TWEAK IOS (/api/verify)
    // ===============================================================================
    if (path === "/api/verify" && request.method === "POST") {
      const allowed = await checkRateLimit(env, clientIp, "verify");
      if (!allowed) {
        return jsonResponse({ valid: false, error: "Quá nhiều yêu cầu! Vui lòng thử lại sau 60 giây." }, 429, corsHeaders);
      }

      const rawText = await request.text();
      const signCheck = await verifyClientRequestSignature(request, rawText, secretSalt);
      if (!signCheck.valid) {
        return jsonResponse({ valid: false, error: signCheck.error, code: signCheck.code }, 401, corsHeaders);
      }

      try {
        const body = JSON.parse(rawText);
        const key = (body.key || "").trim().toUpperCase();
        const hwid = (body.hwid || "").trim();
        const expires_at = Number(body.expires_at ?? 0);
        const signature = (body.signature || "").trim();

        if (!key || !hwid || !signature) {
          return jsonResponse({ valid: false, error: "Thiếu thông tin xác thực!" }, 400, corsHeaders);
        }

        // 1. Kiểm tra chữ ký số HMAC-SHA256
        const signPayload = `${key}|${hwid}|${expires_at}`;
        const expectedSig = await generateSignature(secretSalt, signPayload);

        if (signature !== expectedSig) {
          return jsonResponse({ valid: false, error: "Chữ ký số không hợp lệ (Bị can thiệp)!", code: "INVALID_SIGNATURE" }, 403, corsHeaders);
        }

        // 2. Kiểm tra hết hạn thời gian
        const nowMs = Date.now();
        if (expires_at > 0 && nowMs > expires_at) {
          return jsonResponse({ valid: false, error: "Key đã hết hạn sử dụng!", code: "EXPIRED" }, 403, corsHeaders);
        }

        // 3. Kiểm tra cơ sở dữ liệu
        let keyData = null;
        if (kv) {
          const raw = await kv.get("key:" + key);
          if (raw) {
            try { keyData = JSON.parse(raw); } catch (e) {}
          }
          if (!keyData) {
            const rawLic = await kv.get("lic:" + key);
            if (rawLic) {
              try { keyData = JSON.parse(rawLic); } catch (e) {}
            }
          }
        }
        if (!keyData && MEMORY_KEYS[key]) keyData = MEMORY_KEYS[key];

        if (!keyData) {
          return jsonResponse({ valid: false, error: "Mã key đã bị xóa khỏi hệ thống!", code: "KEY_DELETED" }, 403, corsHeaders);
        }

        if (keyData.status === "REVOKED" || keyData.status === "banned") {
          return jsonResponse({ valid: false, error: "Mã key đã bị khóa bởi Quản trị viên!", code: "KEY_BANNED" }, 403, corsHeaders);
        }

        if (keyData.bound_serial && keyData.bound_serial !== hwid) {
          return jsonResponse({ valid: false, error: "Thiết bị này đã bị gỡ liên kết khỏi key!", code: "DEVICE_UNBOUND" }, 403, corsHeaders);
        }

        // Cập nhật last_seen cho thiết bị
        let dev = null;
        if (kv) {
          const devRaw = await kv.get("device:" + hwid);
          if (devRaw) {
            try { dev = JSON.parse(devRaw); } catch (e) {}
          }
        }
        if (!dev && MEMORY_DEVICES[hwid]) dev = MEMORY_DEVICES[hwid];

        if (dev) {
          if (dev.status === "BANNED") {
            return jsonResponse({ valid: false, error: "Thiết bị này đã bị khóa từ xa!", code: "KEY_BANNED" }, 403, corsHeaders);
          }
          dev.last_seen = Math.floor(Date.now() / 1000);
          dev.last_ip = clientIp;
          if (kv) await kv.put("device:" + hwid, JSON.stringify(dev));
          MEMORY_DEVICES[hwid] = dev;
        }

        return jsonResponse({
          valid: true,
          message: "Bản quyền hợp lệ",
          expires_at: expires_at,
          remaining_seconds: expires_at > 0 ? Math.max(0, Math.floor((expires_at - nowMs) / 1000)) : -1
        }, 200, corsHeaders);
      } catch (err) {
        return jsonResponse({ valid: false, error: err.message }, 400, corsHeaders);
      }
    }
// 1. API KICH HOAT TU APP ANDROID (/api/v1/activate)
    // ===============================================================================
    if (path === "/api/v1/activate" && request.method === "POST") {
      try {
        const { key, serial } = await request.json();
        if (!key || !serial) {
          return jsonResponse({ success: false, message: "Thieu Key hoac Serial may!" }, 400, corsHeaders);
        }

        let keyData = null;
        if (kv) {
          let raw = await kv.get("key:" + key);
          if (!raw) raw = await kv.get("lic:" + key);
          if (!raw) raw = await kv.get(key);
          if (raw) {
            try { keyData = JSON.parse(raw); } catch (e) {}
          }
        }
        
        if (!keyData && MEMORY_KEYS[key]) {
          keyData = MEMORY_KEYS[key];
        }

        // Tu dong nhan dien Key hop le tu Bot hoac he thong neu chua co trong KV
        if (!keyData) {
          const upperKey = key.toUpperCase();
          if (upperKey.startsWith("THANG-") || upperKey.startsWith("VCAM-") || upperKey.startsWith("TEST-")) {
            let durSec = 30 * 86400;
            let durLabel = "30 Ngày";
            if (upperKey.includes("-1D-") || upperKey.includes("-1D")) {
              durSec = 1 * 86400; durLabel = "1 Ngày";
            } else if (upperKey.includes("-7D-") || upperKey.includes("-7D")) {
              durSec = 7 * 86400; durLabel = "7 Ngày";
            } else if (upperKey.includes("-30D-") || upperKey.includes("-30D")) {
              durSec = 30 * 86400; durLabel = "30 Ngày";
            } else if (upperKey.includes("-90D-") || upperKey.includes("-90D")) {
              durSec = 90 * 86400; durLabel = "90 Ngày";
            } else if (upperKey.includes("-180D-") || upperKey.includes("-180D")) {
              durSec = 180 * 86400; durLabel = "180 Ngày";
            } else if (upperKey.includes("-365D-") || upperKey.includes("-365D") || upperKey.includes("-1Y")) {
              durSec = 365 * 86400; durLabel = "365 Ngày";
            } else if (upperKey.includes("-LIFE") || upperKey.includes("-VIP-") || upperKey.includes("VIP-2026")) {
              durSec = 0; durLabel = "Vĩnh viễn";
            }
            keyData = { duration_seconds: durSec, duration_label: durLabel, bound_serial: null, status: "ACTIVE", note: "Kích hoạt qua Telegram Bot" };
          }
        }

        if (!keyData) {
          return jsonResponse({ success: false, message: "Ma kich hoat khong ton tai tren he thong!" }, 404, corsHeaders);
        }

        if (keyData.status === "REVOKED") {
          return jsonResponse({ success: false, message: "Ma key nay da bi thu hoi hoac huy bo boi Admin!" }, 403, corsHeaders);
        }

        if (keyData.bound_serial && keyData.bound_serial !== serial) {
          return jsonResponse({ success: false, message: "Key nay da duoc kich hoat tren thiet bi khac: " + keyData.bound_serial }, 403, corsHeaders);
        }

        // Kiem tra xem may nay co bi Khoa (Ban) khong
        let isBanned = false;
        if (kv) {
          const devRaw = await kv.get("device:" + serial);
          if (devRaw) {
            try {
              if (JSON.parse(devRaw).status === "BANNED") isBanned = true;
            } catch (e) {}
          }
        } else if (MEMORY_DEVICES[serial] && MEMORY_DEVICES[serial].status === "BANNED") {
          isBanned = true;
        }

        if (isBanned) {
          return jsonResponse({ success: false, message: "Thiet bi (Serial: " + serial + ") da bi KHOA tu xa! Lien he Admin de mo khoa." }, 403, corsHeaders);
        }

        // Tinh thoi gian het han
        const now = Math.floor(Date.now() / 1000);
        let expiresAt = 0;
        if (keyData.duration_seconds && keyData.duration_seconds > 0) {
          expiresAt = now + keyData.duration_seconds;
        }
        // Tao chuoi License ky so theo dung chuan LicenseManager
        const licPayload = "SERIAL=" + serial + ";EXPIRES=" + expiresAt + ";ISSUED=" + now;
        const signature = await signLicenseData(licPayload);
        const licenseToken = licPayload + "|SIG=" + signature;

        // Ghi nhan Device & Cap nhat Key bound_serial
        const clientCountry = request.headers.get("cf-ipcountry") || "VN";
        const clientCity = request.cf?.city;
        const location = clientCity ? `${clientCity}, ${clientCountry}` : (clientCountry === "VN" ? "Ho Chi Minh City, VN" : clientCountry);
        const deviceModel = "iPhone";

        keyData.bound_serial = serial;
        keyData.activated_at = now;
        keyData.expires_at = expiresAt;
        keyData.last_ip = clientIp;
        keyData.location = location;
        if (!keyData.device_model) keyData.device_model = deviceModel;

        const devObj = {
          serial: serial,
          key: key,
          model: keyData.device_model,
          buyer_name: keyData.buyer_name || "Khách hàng",
          note: keyData.note || "Khách hàng",
          activated_at: now,
          expires_at: expiresAt,
          duration_label: keyData.duration_label || "Standard",
          last_ip: clientIp,
          location: location,
          last_seen: now,
          status: "ACTIVE"
        };

        if (kv) {
          await kv.put("key:" + key, JSON.stringify(keyData));
          await kv.put("device:" + serial, JSON.stringify(devObj));
        } else {
          MEMORY_KEYS[key] = keyData;
          MEMORY_DEVICES[serial] = devObj;
        }

        return jsonResponse({
          success: true,
          message: "Kich hoat thanh cong thiet bi " + serial + "!",
          license_token: licenseToken,
          license: licenseToken,
          expires_at: expiresAt,
          duration_label: keyData.duration_label,
          server_time: now
        }, 200, corsHeaders);

      } catch (err) {
        return jsonResponse({ success: false, message: "Loi kich hoat Server: " + err.message }, 500, corsHeaders);
      }
    }

    // ===============================================================================
    // 2. API KIEM TRA TRANG THAI THIET BI TU APP (/api/v1/check)
    // ===============================================================================
    if (path === "/api/v1/check" && request.method === "POST") {
      try {
        const { serial } = await request.json();
        if (!serial) return jsonResponse({ success: false, message: "Thieu serial" }, 400, corsHeaders);

        let dev = null;
        if (kv) {
          const raw = await kv.get("device:" + serial);
          if (raw) {
            try { dev = JSON.parse(raw); } catch (e) {}
          }
        }
        if (!dev && MEMORY_DEVICES[serial]) dev = MEMORY_DEVICES[serial];

        if (!dev) {
          return jsonResponse({ success: false, status: "NOT_FOUND", message: "Thiet bi chua duoc kich hoat." }, 404, corsHeaders);
        }

        dev.last_seen = Math.floor(Date.now() / 1000);
        dev.last_ip = clientIp;
        if (kv) await kv.put("device:" + serial, JSON.stringify(dev));

        const now = Math.floor(Date.now() / 1000);
        let isExpired = (dev.expires_at > 0 && dev.expires_at < now);

        return jsonResponse({
          success: true,
          status: dev.status,
          is_expired: isExpired,
          expires_at: dev.expires_at,
          duration_label: dev.duration_label
        }, 200, corsHeaders);
      } catch (err) {
        return jsonResponse({ success: false, message: err.message }, 500, corsHeaders);
      }
    }

    // ===============================================================================
    // AUTH 1. API DANG NHAP ADMIN (/api/admin/login)
    // ===============================================================================
    if (path === "/api/admin/login" && request.method === "POST") {
      try {
        const { username, password, otp } = await request.json();
        const creds = await getAdminCredentials(env);
        if (!creds.isConfigured) {
          return jsonResponse({
            success: false,
            message: "Hệ thống chưa thiết lập ADMIN_PASS hoặc TWO_FACTOR_SECRET trong mục Variables and Secrets trên Cloudflare Worker!"
          }, 500, corsHeaders);
        }
        if (username !== creds.user || password !== creds.pass) {
          return jsonResponse({ success: false, message: "Sai tên đăng nhập hoặc mật khẩu!" }, 401, corsHeaders);
        }

        const isOtpValid = await verifyTotp(creds.secret2fa, otp);
        if (!isOtpValid) {
          return jsonResponse({ success: false, message: "Mã 2FA Google Authenticator không đúng hoặc đã hết hạn (30s)!" }, 401, corsHeaders);
        }

        const sessionToken = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
        const sessionObj = {
          user: creds.user,
          created_at: Date.now(),
          expires_at: Date.now() + 7 * 86400 * 1000
        };

        if (kv) {
          await kv.put("session:" + sessionToken, JSON.stringify(sessionObj), { expirationTtl: 7 * 86400 });
        }
        MEMORY_SESSIONS[sessionToken] = sessionObj;

        const cookie = "vcam_session=" + sessionToken + "; Path=/; Max-Age=604800; HttpOnly; Secure; SameSite=Lax";
        return jsonResponse(
          { success: true, message: "Đăng nhập thành công!", token: sessionToken },
          200,
          { ...corsHeaders, "Set-Cookie": cookie }
        );
      } catch (err) {
        return jsonResponse({ success: false, message: "Lỗi đăng nhập: " + err.message }, 500, corsHeaders);
      }
    }

    // ===============================================================================
    // AUTH 2. API DANG XUAT ADMIN (/api/admin/logout)
    // ===============================================================================
    if (path === "/api/admin/logout") {
      const token = getCookie(request, "vcam_session");
      if (token) {
        if (kv) await kv.delete("session:" + token);
        delete MEMORY_SESSIONS[token];
      }
      const expiredCookie = "vcam_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax";
      if (request.method === "GET") {
        return new Response(null, {
          status: 302,
          headers: { Location: "/a", "Set-Cookie": expiredCookie }
        });
      }
      return jsonResponse({ success: true, message: "Đã đăng xuất!" }, 200, { ...corsHeaders, "Set-Cookie": expiredCookie });
    }

    // ===============================================================================
    // AUTH GUARD: CHAN TAT CA CAC REQUEST /api/admin/* KHI CHUA DANG NHAP
    // ===============================================================================
    if (path.startsWith("/api/admin/") && path !== "/api/admin/login") {
      const authorized = await isAuthorizedAdmin(request, env);
      if (!authorized) {
        return jsonResponse({ success: false, error: "Phiên đăng nhập đã hết hạn hoặc chưa đăng nhập!" }, 401, corsHeaders);
      }
    }

    // ===============================================================================
    // 3. ADMIN API: LAY DANH SACH THIET BI VA DANH SACH KEY (/api/admin/devices)
    // ===============================================================================
    if (path === "/api/admin/devices") {
      const devices = [];
      const keys = [];

      if (kv) {
        // 1. Quét danh sách thiết bị có prefix 'device:'
        try {
          const devList = await kv.list({ prefix: "device:" });
          for (const k of devList.keys) {
            const val = await kv.get(k.name);
            if (val) {
              try { devices.push(JSON.parse(val)); } catch (e) {}
            }
          }
        } catch (_) {}

        // 2. Thu thập toàn bộ key names (cả 'key:', 'lic:', và danh sách quét chung)
        const seenKeyNames = new Set();
        try {
          const keyList = await kv.list({ prefix: "key:" });
          for (const item of keyList.keys) seenKeyNames.add(item.name);
        } catch (_) {}

        try {
          const licList = await kv.list({ prefix: "lic:" });
          for (const item of licList.keys) seenKeyNames.add(item.name);
        } catch (_) {}

        try {
          const allList = await kv.list();
          for (const item of allList.keys) {
            const nm = item.name;
            if (nm.startsWith("rl:") || nm.startsWith("session:") || nm.startsWith("config:") || nm.startsWith("order:") || nm.startsWith("tele_") || nm.startsWith("device:")) {
              continue;
            }
            seenKeyNames.add(nm);
          }
        } catch (_) {}

        // 3. Đọc và chuẩn hóa dữ liệu từng key cũ & mới
        for (const name of seenKeyNames) {
          try {
            const val = await kv.get(name);
            if (!val) continue;
            const kObj = JSON.parse(val);
            if (!kObj || typeof kObj !== "object") continue;

            const realKeyCode = (kObj.key || name.replace(/^(key:|lic:)/, "")).trim().toUpperCase();
            kObj.key = realKeyCode;

            // Chuẩn hóa thời gian tạo (created_at)
            if (kObj.created_at) {
              if (kObj.created_at > 1e11) {
                kObj.created_at = Math.floor(kObj.created_at / 1000);
              }
            } else {
              kObj.created_at = Math.floor(Date.now() / 1000);
            }

            // Chuẩn hóa thời hạn & label
            if (!kObj.duration_label) {
              if (kObj.duration_days !== undefined) {
                kObj.duration_label = kObj.duration_days === 0 ? "Vĩnh viễn" : `${kObj.duration_days} Ngày`;
                kObj.duration_seconds = kObj.duration_days * 86400;
              } else if (kObj.duration_seconds !== undefined) {
                kObj.duration_label = kObj.duration_seconds === 0 ? "Vĩnh viễn" : `${Math.round(kObj.duration_seconds / 86400)} Ngày`;
              } else {
                kObj.duration_label = "30 Ngày";
              }
            }

            // Chuẩn hóa thiết bị đã gắn (hỗ trợ cả cấu trúc devices cũ)
            if (!kObj.bound_serial) {
              if (Array.isArray(kObj.devices) && kObj.devices.length > 0 && kObj.devices[0].hwid) {
                kObj.bound_serial = kObj.devices[0].hwid;
              } else if (kObj.hwid) {
                kObj.bound_serial = kObj.hwid;
              }
            }

            if (!kObj.device_model) {
              if (Array.isArray(kObj.devices) && kObj.devices.length > 0 && kObj.devices[0].device_name) {
                kObj.device_model = kObj.devices[0].device_name;
              } else {
                kObj.device_model = "iPhone";
              }
            }

            // Chuẩn hóa thời gian hết hạn (expires_at)
            const nowSec = Math.floor(Date.now() / 1000);
            const nowMs = Date.now();
            let isExp = false;
            if (kObj.expires_at && kObj.expires_at > 0) {
              isExp = (kObj.expires_at > 1e11 ? kObj.expires_at <= nowMs : kObj.expires_at <= nowSec);
            }

            // Chuẩn hóa trạng thái (status)
            const rawStatus = String(kObj.status || "").toUpperCase();
            if (rawStatus === "REVOKED" || rawStatus === "BANNED") {
              kObj.status = "REVOKED";
            } else if (isExp) {
              kObj.status = "EXPIRED";
            } else if (!kObj.bound_serial || rawStatus === "UNACTIVATED" || rawStatus === "UNUSED") {
              kObj.status = "UNUSED";
            } else {
              kObj.status = "ACTIVE";
            }

            if (!kObj.buyer_name) kObj.buyer_name = kObj.note || "Khách hàng";
            if (!kObj.price) kObj.price = "0 đ";
            if (!kObj.social_platform) kObj.social_platform = "Telegram";
            if (!kObj.social_account) kObj.social_account = "Chưa lưu";

            if (!keys.some(x => x.key === realKeyCode)) {
              keys.push(kObj);
            }

            // Bổ sung thiết bị vào danh sách devices nếu chưa có
            if (kObj.bound_serial && !devices.some(d => d.serial === kObj.bound_serial)) {
              devices.push({
                serial: kObj.bound_serial,
                key: realKeyCode,
                model: kObj.device_model || "iPhone",
                buyer_name: kObj.buyer_name,
                note: kObj.note || "",
                activated_at: kObj.activated_at || kObj.created_at,
                expires_at: kObj.expires_at,
                duration_label: kObj.duration_label,
                last_ip: kObj.last_ip || "N/A",
                location: kObj.location || "N/A",
                last_seen: kObj.activated_at || kObj.created_at,
                status: kObj.status === "REVOKED" ? "BANNED" : "ACTIVE"
              });
            }
          } catch (e) {}
        }
      }

      for (const s in MEMORY_DEVICES) {
        if (!devices.some(d => d.serial === s)) devices.push(MEMORY_DEVICES[s]);
      }
      for (const k in MEMORY_KEYS) {
        if (!keys.some(x => x.key === k)) keys.push(MEMORY_KEYS[k]);
      }

      devices.sort((a, b) => (b.activated_at || 0) - (a.activated_at || 0));
      keys.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));

      return jsonResponse({
        success: true,
        kv_bound: !!kv,
        kv_name: kvName,
        env_keys: Object.keys(env || {}),
        devices,
        keys
      }, 200, corsHeaders);
    }

    // ===============================================================================
    // 4. ADMIN API: KHOA / MO KHOA / GIA HAN / XOA THIET BI (/api/admin/device-action)
    // ===============================================================================
    if (path === "/api/admin/device-action" && request.method === "POST") {
      try {
        const { action, serial, days_add } = await request.json();

        let dev = null;
        if (kv) {
          const raw = await kv.get("device:" + serial);
          if (raw) {
            try { dev = JSON.parse(raw); } catch (e) {}
          }
        }
        if (!dev && MEMORY_DEVICES[serial]) dev = MEMORY_DEVICES[serial];

        if (!dev) {
          return jsonResponse({ error: "Khong tim thay thiet bi: " + serial }, 404, corsHeaders);
        }

        if (action === "ban") {
          dev.status = "BANNED";
          if (kv) await kv.put("device:" + serial, JSON.stringify(dev));
          MEMORY_DEVICES[serial] = dev;
          return jsonResponse({ success: true, message: "Da KHOA thiet bi: " + serial }, 200, corsHeaders);
        }

        if (action === "unban") {
          dev.status = "ACTIVE";
          if (kv) await kv.put("device:" + serial, JSON.stringify(dev));
          MEMORY_DEVICES[serial] = dev;
          return jsonResponse({ success: true, message: "Da MO KHOA cho may: " + serial }, 200, corsHeaders);
        }

        if (action === "extend") {
          const days = parseInt(days_add) || 30;
          const addSec = days * 86400;
          const now = Math.floor(Date.now() / 1000);
          if (!dev.expires_at || dev.expires_at < now) {
            dev.expires_at = now + addSec;
          } else {
            dev.expires_at += addSec;
          }
          dev.status = "ACTIVE";
          dev.duration_label = (dev.duration_label || "") + " (+" + days + "N)";
          if (kv) await kv.put("device:" + serial, JSON.stringify(dev));
          MEMORY_DEVICES[serial] = dev;
          return jsonResponse({ success: true, message: "Da gia han them " + days + " ngay cho may " + serial }, 200, corsHeaders);
        }

        if (action === "delete") {
          if (kv) await kv.delete("device:" + serial);
          delete MEMORY_DEVICES[serial];
          return jsonResponse({ success: true, message: "Da xoa thiet bi: " + serial }, 200, corsHeaders);
        }

        return jsonResponse({ error: "Hanh dong khong hop le" }, 400, corsHeaders);
      } catch (err) {
        return jsonResponse({ error: err.message }, 500, corsHeaders);
      }
    }

    // ===============================================================================
    // 5. ADMIN API: THAO TAC TREN KEY (/api/admin/key-action)
    // ===============================================================================
    if (path === "/api/admin/key-action" && request.method === "POST") {
      try {
        const { action, key } = await request.json();

        if (!key) return jsonResponse({ error: "Thieu ma key!" }, 400, corsHeaders);

        let keyObj = null;
        if (kv) {
          let raw = await kv.get("key:" + key);
          if (!raw) raw = await kv.get("lic:" + key);
          if (!raw) raw = await kv.get(key);
          if (raw) {
            try { keyObj = JSON.parse(raw); } catch (e) {}
          }
        }
        if (!keyObj && MEMORY_KEYS[key]) keyObj = MEMORY_KEYS[key];

        if (!keyObj && action !== "delete") {
          return jsonResponse({ error: "Khong tim thay key: " + key }, 404, corsHeaders);
        }

        if (action === "delete") {
          if (kv) {
            await kv.delete("key:" + key);
            await kv.delete("lic:" + key);
            await kv.delete(key);
          }
          delete MEMORY_KEYS[key];
          return jsonResponse({ success: true, message: "Da xoa ma key " + key + " khoi he thong." }, 200, corsHeaders);
        }

        if (action === "revoke") {
          keyObj.status = "REVOKED";
          if (kv) {
            await kv.put("key:" + key, JSON.stringify(keyObj));
            await kv.delete("lic:" + key);
          }
          MEMORY_KEYS[key] = keyObj;
          return jsonResponse({ success: true, message: "Da khoa ma key: " + key }, 200, corsHeaders);
        }

        if (action === "restore") {
          keyObj.status = "ACTIVE";
          if (kv) {
            await kv.put("key:" + key, JSON.stringify(keyObj));
            await kv.delete("lic:" + key);
          }
          MEMORY_KEYS[key] = keyObj;
          return jsonResponse({ success: true, message: "Da mo khoa ma key: " + key }, 200, corsHeaders);
        }

        if (action === "reset-device") {
          const oldSerial = keyObj.bound_serial || (Array.isArray(keyObj.devices) && keyObj.devices[0] ? keyObj.devices[0].hwid : null);
          keyObj.bound_serial = null;
          keyObj.devices = [];
          keyObj.activated_at = null;
          keyObj.expires_at = null;
          keyObj.last_ip = null;
          keyObj.location = null;
          keyObj.device_model = null;
          if (kv) {
            await kv.put("key:" + key, JSON.stringify(keyObj));
            await kv.delete("lic:" + key);
            if (oldSerial) await kv.delete("device:" + oldSerial);
          }
          MEMORY_KEYS[key] = keyObj;
          if (oldSerial) delete MEMORY_DEVICES[oldSerial];
          return jsonResponse({ success: true, message: "Đã gỡ thiết bị cho key: " + key + ". Khách hàng có thể kích hoạt trên máy mới!" }, 200, corsHeaders);
        }

        return jsonResponse({ error: "Lenh khong hop le" }, 400, corsHeaders);
      } catch (err) {
        return jsonResponse({ error: err.message }, 500, corsHeaders);
      }
    }

    // ===============================================================================
    // 6. ADMIN API: TAO MA ACTIVE KEY MOI (/api/admin/create-key)
    // ===============================================================================
    if (path === "/api/admin/create-key" && request.method === "POST") {
      try {
        const {
          duration_type,
          duration_val,
          duration_label,
          price,
          buyer_name,
          social_platform,
          social_account,
          note,
          prefix
        } = await request.json();

        let durationSec = 7 * 86400;
        let label = duration_label || "7 Ngày";

        if (duration_type === "hours") {
          const h = parseFloat(duration_val) || 1;
          durationSec = Math.round(h * 3600);
          label = h + " Giờ";
        } else if (duration_type === "days") {
          const d = parseFloat(duration_val) || 1;
          durationSec = Math.round(d * 86400);
          label = d + " Ngày";
        } else if (duration_type === "lifetime") {
          durationSec = 0;
          label = "Vĩnh viễn";
        }

        const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        let cleanPrefix = (prefix || "VITAMIN").trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
        if (cleanPrefix.length > 7) {
          cleanPrefix = cleanPrefix.substring(0, 7);
        }
        if (!cleanPrefix) cleanPrefix = "VITAMIN";

        let randomSuffix = "";
        for (let i = 0; i < 7; i++) {
          randomSuffix += chars.charAt(Math.floor(Math.random() * chars.length));
        }

        const code = cleanPrefix + "-" + randomSuffix;

        const keyObj = {
          key: code,
          duration_seconds: durationSec,
          duration_label: label,
          price: parseInt(price) || 0,
          buyer_name: (buyer_name || "").trim() || "Khách hàng",
          social_platform: social_platform || "Telegram",
          social_account: (social_account || "").trim(),
          note: (note || "").trim(),
          bound_serial: null,
          device_model: null,
          last_ip: null,
          location: null,
          created_at: Math.floor(Date.now() / 1000),
          activated_at: null,
          expires_at: null,
          status: "ACTIVE"
        };

        if (kv) {
          await kv.put("key:" + code, JSON.stringify(keyObj));
        } else {
          MEMORY_KEYS[code] = keyObj;
        }

        return jsonResponse({
          success: true,
          key: keyObj,
          kv_bound: !!kv,
          kv_name: kvName
        }, 200, corsHeaders);
      } catch (err) {
        return jsonResponse({ error: "Loi tao key: " + err.message }, 500, corsHeaders);
      }
    }

    // ===============================================================================
    
      // COMPAT: GET /api/admin/keys
      if (path === "/api/admin/keys" && request.method === "GET") {
        const keys = [];
        if (kv) {
          const keyList = await kv.list({ prefix: "key:" });
          for (const k of keyList.keys) {
            const val = await kv.get(k.name);
            if (val) { try { keys.push(JSON.parse(val)); } catch (e) {} }
          }
        }
        for (const k in MEMORY_KEYS) {
          if (!keys.some(x => x.key === k)) keys.push(MEMORY_KEYS[k]);
        }
        keys.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
        return jsonResponse({ total: keys.length, keys }, 200, corsHeaders);
      }

      // COMPAT: POST /api/admin/toggle-ban
      if (path === "/api/admin/toggle-ban" && request.method === "POST") {
        const body = await request.json().catch(() => ({}));
        const key = (body.key || "").trim().toUpperCase();
        let keyObj = null;
        if (kv) {
          const raw = await kv.get("key:" + key);
          if (raw) { try { keyObj = JSON.parse(raw); } catch (e) {} }
        }
        if (!keyObj && MEMORY_KEYS[key]) keyObj = MEMORY_KEYS[key];
        if (!keyObj) return jsonResponse({ error: "Không tìm thấy key!" }, 404, corsHeaders);

        if (keyObj.status === "REVOKED" || keyObj.status === "banned") {
          keyObj.status = "ACTIVE";
        } else {
          keyObj.status = "REVOKED";
        }
        if (kv) await kv.put("key:" + key, JSON.stringify(keyObj));
        MEMORY_KEYS[key] = keyObj;
        return jsonResponse({ success: true, message: "Đã cập nhật trạng thái key: " + key, record: keyObj }, 200, corsHeaders);
      }

      // COMPAT: POST /api/admin/reset-hwid
      if (path === "/api/admin/reset-hwid" && request.method === "POST") {
        const body = await request.json().catch(() => ({}));
        const key = (body.key || "").trim().toUpperCase();
        let keyObj = null;
        if (kv) {
          const raw = await kv.get("key:" + key);
          if (raw) { try { keyObj = JSON.parse(raw); } catch (e) {} }
        }
        if (!keyObj && MEMORY_KEYS[key]) keyObj = MEMORY_KEYS[key];
        if (!keyObj) return jsonResponse({ error: "Không tìm thấy key!" }, 404, corsHeaders);

        const oldSerial = keyObj.bound_serial;
        keyObj.bound_serial = null;
        keyObj.devices = [];
        if (kv) {
          await kv.put("key:" + key, JSON.stringify(keyObj));
          if (oldSerial) await kv.delete("device:" + oldSerial);
        }
        MEMORY_KEYS[key] = keyObj;
        if (oldSerial) delete MEMORY_DEVICES[oldSerial];
        return jsonResponse({ success: true, message: "Đã reset thiết bị cho key: " + key }, 200, corsHeaders);
      }

      // COMPAT: POST /api/admin/delete-key
      if (path === "/api/admin/delete-key" && request.method === "POST") {
        const body = await request.json().catch(() => ({}));
        const key = (body.key || "").trim().toUpperCase();
        if (kv) await kv.delete("key:" + key);
        delete MEMORY_KEYS[key];
        return jsonResponse({ success: true, message: "Đã xóa vĩnh viễn key: " + key }, 200, corsHeaders);
      }

    // ===============================================================================
    // 7. GIAO DIỆN WEB QUẢN TRỊ ADMIN (/a, /admin, /)
    // ===============================================================================
    if (path === "/a" || path === "/admin" || path === "/") {
      const authorized = await isAuthorizedAdmin(request, env);
      const creds = await getAdminCredentials(env);
      if (!authorized) {
        return new Response(getLoginHtml(creds.secret2fa, creds.isConfigured), {
          headers: {
            "Content-Type": "text/html; charset=UTF-8",
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
            ...corsHeaders
          }
        });
      }
      return new Response(getDashboardHtml(creds), {
        headers: {
          "Content-Type": "text/html; charset=UTF-8",
          "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
          "Pragma": "no-cache",
          ...corsHeaders
        }
      });
    }

    // ===============================================================================
    // 8. TELEGRAM BOT WEBHOOK (Chạy 24/24 trên Cloudflare Workers)
    // ===============================================================================
    if (path === "/api/v1/telegram-webhook" && request.method === "POST") {
      try {
        const update = await request.json();
        if (ctx && typeof ctx.waitUntil === "function") {
          ctx.waitUntil(handleTelegramUpdate(update, env));
        } else {
          await handleTelegramUpdate(update, env);
        }
        return jsonResponse({ ok: true });
      } catch (e) {
        return jsonResponse({ ok: false, error: e.message }, 500);
      }
    }

    if (path === "/api/v1/telegram-set-webhook") {
      const cfg = await getTelegramConfig(env);
      const webhookUrl = `https://${url.host}/api/v1/telegram-webhook`;
      const teleRes = await teleApi(cfg.bot_token, "setWebhook", {
        url: webhookUrl,
        drop_pending_updates: true
      });
      return jsonResponse({
        success: teleRes.ok,
        webhook_url: webhookUrl,
        telegram_response: teleRes,
        message: teleRes.ok 
          ? "✅ Đã kích hoạt Telegram Bot chạy 24/24 trên Cloudflare Workers thành công!" 
          : "❌ Thiết lập Webhook thất bại, vui lòng kiểm tra bot token!"
      }, 200, corsHeaders);
    }

    if (path === "/api/v1/telegram-webhook-info") {
      const cfg = await getTelegramConfig(env);
      const teleRes = await teleApi(cfg.bot_token, "getWebhookInfo", {});
      return jsonResponse(teleRes, 200, corsHeaders);
    }

    return jsonResponse({ error: "Not Found", path: path }, 404, corsHeaders);
  }
};
// MODULE TELEGRAM BOT TRÊN CLOUDFLARE WORKERS (CHẠY 24/24 MIỄN PHÍ)
// ===============================================================================

const DEFAULT_TELE_CONFIG = {
  bot_token: "",
  admin_username: "gitisgit",
  admin_chat_id: 5469372459,
  order_prefix: "NAP",
  bank: {
    bank_code: "SHB",
    bank_name: "SHB",
    account_no: "0110091989",
    account_name: "NGUYEN THI TY"
  },
  usdt: {
    network: "TRC20",
    address: "THKNF3W2BQ9bLqtJQUyNXqjHzjaXmcXXRj",
    note: "Chuyển đúng mạng TRC20"
  },
  packages: {
    "1d":   { name: "Gói 1 Ngày",          days: 1,   price: 50000,   price_usdt: 2,   label: "1 Ngày" },
    "7d":   { name: "Gói 7 Ngày",          days: 7,   price: 180000,  price_usdt: 7,   label: "7 Ngày" },
    "30d":  { name: "Gói 30 Ngày",         days: 30,  price: 500000,  price_usdt: 20,  label: "30 Ngày" },
    "90d":  { name: "Gói 90 Ngày",         days: 90,  price: 1200000, price_usdt: 48,  label: "90 Ngày" },
    "180d": { name: "Gói 180 Ngày",        days: 180, price: 2100000, price_usdt: 84,  label: "180 Ngày" },
    "365d": { name: "Gói 365 Ngày (1 Năm)", days: 365, price: 3600000, price_usdt: 144, label: "365 Ngày" },
    "life": { name: "Gói Vĩnh Viễn",       days: 0,   price: 6000000, price_usdt: 240, label: "Vĩnh Viễn" }
  },
  app_download_url: "https://vios.hothangtech.workers.dev"
};

function formatVnd(num) {
  return (num || 0).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".") + "đ";
}

async function getTelegramConfig(env) {
  const { kv } = getKV(env);
  let cfg = JSON.parse(JSON.stringify(DEFAULT_TELE_CONFIG));

  if (env) {
    if (env.TELEGRAM_BOT_TOKEN || env.BOT_TOKEN) {
      cfg.bot_token = (env.TELEGRAM_BOT_TOKEN || env.BOT_TOKEN).trim();
    }
    if (env.TELEGRAM_ADMIN_CHAT_ID || env.ADMIN_CHAT_ID) {
      const parsedId = parseInt(env.TELEGRAM_ADMIN_CHAT_ID || env.ADMIN_CHAT_ID, 10);
      if (!isNaN(parsedId)) cfg.admin_chat_id = parsedId;
    }
    if (env.BANK_ID || env.BANK_CODE) {
      cfg.bank.bank_code = (env.BANK_ID || env.BANK_CODE).trim().toUpperCase();
      cfg.bank.bank_name = cfg.bank.bank_code;
    }
    if (env.BANK_ACCOUNT || env.ACCOUNT_NO) {
      cfg.bank.account_no = (env.BANK_ACCOUNT || env.ACCOUNT_NO).trim();
    }
    if (env.BANK_NAME || env.ACCOUNT_NAME) {
      cfg.bank.account_name = (env.BANK_NAME || env.ACCOUNT_NAME).trim().toUpperCase();
    }
    if (env.USDT_NETWORK) {
      cfg.usdt.network = env.USDT_NETWORK.trim().toUpperCase();
    }
    if (env.USDT_ADDRESS) {
      cfg.usdt.address = env.USDT_ADDRESS.trim();
    }
  }

  if (kv) {
    try {
      const stored = await kv.get("config:telegram_bot");
      if (stored) {
        const parsed = JSON.parse(stored);
        return {
          ...cfg,
          ...parsed,
          bank: { ...cfg.bank, ...(parsed.bank || {}) },
          usdt: { ...cfg.usdt, ...(parsed.usdt || {}) },
          packages: { ...cfg.packages, ...(parsed.packages || {}) }
        };
      }
    } catch (e) {}
  }
  return cfg;
}

async function saveTelegramConfig(env, cfg) {
  const { kv } = getKV(env);
  if (kv) {
    try {
      await kv.put("config:telegram_bot", JSON.stringify(cfg));
    } catch (e) {}
  }
}

async function teleApi(token, method, payload) {
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    return await res.json();
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

async function sendTeleMessage(token, chatId, text, replyMarkup = null) {
  const payload = {
    chat_id: chatId,
    text: text,
    parse_mode: "HTML",
    disable_web_page_preview: true
  };
  if (replyMarkup) payload.reply_markup = replyMarkup;
  return await teleApi(token, "sendMessage", payload);
}

async function sendTelePhoto(token, chatId, photo, caption = "", replyMarkup = null) {
  const payload = {
    chat_id: chatId,
    photo: photo,
    caption: caption,
    parse_mode: "HTML"
  };
  if (replyMarkup) payload.reply_markup = replyMarkup;
  return await teleApi(token, "sendPhoto", payload);
}

async function editTeleCaption(token, chatId, messageId, caption) {
  return await teleApi(token, "editMessageCaption", {
    chat_id: chatId,
    message_id: messageId,
    caption: caption,
    parse_mode: "HTML"
  });
}

async function editTeleText(token, chatId, messageId, text) {
  return await teleApi(token, "editMessageText", {
    chat_id: chatId,
    message_id: messageId,
    text: text,
    parse_mode: "HTML",
    disable_web_page_preview: true
  });
}

async function answerTeleCallback(token, callbackQueryId, text = "", showAlert = false) {
  return await teleApi(token, "answerCallbackQuery", {
    callback_query_id: callbackQueryId,
    text: text,
    show_alert: showAlert
  });
}

function generateRandomKey(pkgKey = "30d") {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  let suffix = "";
  for (let i = 0; i < 5; i++) {
    suffix += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  let tag = "30D";
  const k = (pkgKey || "30d").toLowerCase();
  if (k === "1d" || k === "1") tag = "1D";
  else if (k.includes("7")) tag = "7D";
  else if (k.includes("180")) tag = "180D";
  else if (k.includes("365") || k.includes("1y")) tag = "365D";
  else if (k.includes("90")) tag = "90D";
  else if (k.includes("30")) tag = "30D";
  else if (k.includes("life") || k.includes("vinh")) tag = "LIFE";
  return `VITAMIN-${tag}-${suffix}`;
}

async function createTelegramOrder(env, customerId, customerUsername, pkgKey, method = "VND") {
  const cfg = await getTelegramConfig(env);
  const pkg = cfg.packages[pkgKey];
  if (!pkg) return null;

  const prefix = (cfg.order_prefix || "NAP").trim().toUpperCase();
  const codeNum = Math.floor(1000 + Math.random() * 9000);
  const orderId = prefix + codeNum;
  const order = {
    order_id: orderId,
    customer_id: customerId,
    customer_username: customerUsername || "N/A",
    package_key: pkgKey,
    package_name: pkg.name,
    days: pkg.days,
    price: pkg.price,
    price_usdt: pkg.price_usdt || 0,
    method: method,
    label: pkg.label,
    created_at: Math.floor(Date.now() / 1000),
    status: "PENDING",
    key_issued: null,
    payment_note: null
  };

  const { kv } = getKV(env);
  if (kv) {
    await kv.put("tele_order:" + orderId, JSON.stringify(order), { expirationTtl: 86400 * 7 });
    await kv.put("tele_user_pending:" + customerId, orderId, { expirationTtl: 86400 * 7 });
  } else {
    MEMORY_KEYS["tele_order:" + orderId] = order;
    MEMORY_KEYS["tele_user_pending:" + customerId] = orderId;
  }
  return order;
}

async function getTelegramOrder(env, orderId) {
  const { kv } = getKV(env);
  if (kv) {
    const raw = await kv.get("tele_order:" + orderId);
    if (raw) {
      try { return JSON.parse(raw); } catch (e) {}
    }
  } else {
    return MEMORY_KEYS["tele_order:" + orderId] || null;
  }
  return null;
}

async function saveTelegramOrder(env, order) {
  const { kv } = getKV(env);
  if (kv) {
    await kv.put("tele_order:" + order.order_id, JSON.stringify(order), { expirationTtl: 86400 * 30 });
  } else {
    MEMORY_KEYS["tele_order:" + order.order_id] = order;
  }
}

async function getUserPendingOrder(env, customerId) {
  const { kv } = getKV(env);
  let orderId = null;
  if (kv) {
    orderId = await kv.get("tele_user_pending:" + customerId);
  } else {
    orderId = MEMORY_KEYS["tele_user_pending:" + customerId];
  }
  if (!orderId) return null;
  const o = await getTelegramOrder(env, orderId);
  if (o && o.status === "PENDING") return o;
  return null;
}

async function handleTelegramUpdate(u, env) {
  const cfg = await getTelegramConfig(env);
  const token = cfg.bot_token;
  const adminUser = (cfg.admin_username || "").toLowerCase().replace(/^@/, "");

  // 1. Xử lý Callback query (Bấm nút trên menu)
  if (u.callback_query) {
    const cb = u.callback_query;
    const data = cb.data || "";
    const chatId = cb.message?.chat?.id;
    const user = cb.from || {};

    if (data === "menu_buy") {
      await showMenuBuy(token, cfg, chatId);
    } else if (data.startsWith("choose_") || data.startsWith("buy_")) {
      const pkgKey = data.replace("choose_", "").replace("buy_", "");
      await showSelectMethod(token, cfg, chatId, pkgKey);
    } else if (data.startsWith("pay_vnd_")) {
      const pkgKey = data.replace("pay_vnd_", "");
      await processBuyVnd(token, cfg, env, chatId, user.username, pkgKey);
    } else if (data.startsWith("pay_usdt_")) {
      const pkgKey = data.replace("pay_usdt_", "");
      await processBuyUsdt(token, cfg, env, chatId, user.username, pkgKey);
    } else if (data === "menu_back") {
      await showStartMessage(token, cfg, env, chatId, user.username, user.first_name);
    } else if (data === "menu_guide") {
      await sendTeleMessage(token, chatId, 
        `📖 <b>HƯỚNG DẪN SỬ DỤNG VCAM ASSISTANT:</b>\n\n` +
        `1. Cài đặt Magisk Module <code>vcam_native_hook.zip</code> qua Magisk / KernelSU.\n` +
        `2. Cài app <code>CameraAssistant.apk</code>.\n` +
        (cfg.app_download_url ? `   👉 Link tải App APK: ${cfg.app_download_url}\n` : "") +
        `3. Mua Key và kích hoạt bản quyền trong app.\n` +
        `4. Chọn Video (.mp4), Audio (.mp3) hoặc Hình ảnh (.jpg) nguồn.\n` +
        `5. Bật <i>Kích hoạt Camera Ảo</i> và mở ứng dụng cần dùng!\n\n` +
        `💬 Hỗ trợ trực tiếp: @${cfg.admin_username}`
      );
    } else if (data.startsWith("approve_")) {
      const oid = data.replace("approve_", "");
      await processApproveOrder(token, cfg, env, cb, oid);
    } else if (data.startsWith("reject_")) {
      const oid = data.replace("reject_", "");
      await processRejectOrder(token, cfg, env, cb, oid);
    } else if (data.startsWith("cancel_")) {
      const oid = data.replace("cancel_", "");
      const order = await getTelegramOrder(env, oid);
      if (order) {
        order.status = "CANCELLED";
        await saveTelegramOrder(env, order);
        const { kv } = getKV(env);
        if (kv) await kv.delete("tele_user_pending:" + order.customer_id);
      }
      await sendTeleMessage(token, chatId, `Đã hủy đơn hàng #${oid}.`);
    }
    return;
  }

  // 2. Xử lý tin nhắn thường
  if (u.message) {
    const m = u.message;
    const chatId = m.chat?.id;
    const fromUser = m.from || {};
    const username = (fromUser.username || "").toLowerCase().replace(/^@/, "");
    const firstName = fromUser.first_name || "Bạn";
    const text = (m.text || "").trim();
    const isAdmin = (username === adminUser) || (chatId && String(chatId) === String(cfg.admin_chat_id));

    // Gửi ảnh biên lai
    if (m.photo && m.photo.length > 0) {
      const photoFileId = m.photo[m.photo.length - 1].file_id;
      await processPhotoBill(token, cfg, env, chatId, fromUser.username, photoFileId);
      return;
    }

    if (text.startsWith("/start")) {
      await showStartMessage(token, cfg, env, chatId, fromUser.username, firstName);
    } else if (text.startsWith("/muakey")) {
      await showMenuBuy(token, cfg, chatId);
    } else if (text.startsWith("/caidat")) {
      if (isAdmin) {
        let rows = "";
        for (const [k, v] of Object.entries(cfg.packages)) {
          rows += `• ${v.name} (<code>${k}</code>): <b>${formatVnd(v.price)}</b> | <b>${v.price_usdt || 0} USDT</b>\n`;
        }
        await sendTeleMessage(token, chatId,
          `⚙️ <b>CẤU HÌNH CLOUDFLARE WORKER BOT:</b>\n\n` +
          `👑 <b>Admin:</b> @${cfg.admin_username} (ID: <code>${cfg.admin_chat_id}</code>)\n\n` +
          `🏦 <b>Ngân hàng (VNĐ):</b>\n` +
          `• Ngân hàng: ${cfg.bank.bank_name} (${cfg.bank.bank_code})\n` +
          `• STK: <code>${cfg.bank.account_no}</code>\n` +
          `• Chủ TK: ${cfg.bank.account_name}\n\n` +
          `📝 <b>Cú pháp CK (Nội dung chuyển khoản):</b>\n` +
          `• Tiền tố mã đơn: <b>${cfg.order_prefix || "NAP"}</b> (Nội dung CK: <code>${cfg.order_prefix || "NAP"}xxxx</code>)\n\n` +
          `📥 <b>Link tải APK hiện tại:</b>\n` +
          `• <code>${cfg.app_download_url || "Chưa cài"}</code>\n\n` +
          `🪙 <b>Ví Crypto (USDT):</b>\n` +
          `• Mạng: <b>${cfg.usdt.network}</b>\n` +
          `• Địa chỉ ví: <code>${cfg.usdt.address}</code>\n\n` +
          `💎 <b>Bảng giá hiện tại (VNĐ / USDT):</b>\n${rows}\n` +
          `🛠 <b>LỆNH CÀI ĐẶT NHANH:</b>\n` +
          `• <code>/setapk https://...</code> - Đổi link tải APK\n` +
          `• <code>/setprefix NAP</code> - Đổi tiền tố nội dung CK (VD: NAPxxxx)\n` +
          `• <code>/setbank MB STK CTK</code> - Đổi ngân hàng\n` +
          `• <code>/setusdt TRC20 &lt;địa_chỉ_ví&gt;</code> - Cài ví USDT\n` +
          `• <code>/setgia 30d 500000</code> - Đổi giá VNĐ gói 30 ngày\n` +
          `• <code>/setgiausdt 30d 20</code> - Đổi giá USDT gói 30 ngày\n` +
          `• <code>/taokey 30d</code> - Tạo key kích hoạt thủ công`
        );
      }
    } else if (text.startsWith("/setapk")) {
      if (isAdmin) {
        const parts = text.split(/\s+/);
        if (parts.length >= 2) {
          const apkUrl = parts.slice(1).join(" ").trim();
          cfg.app_download_url = apkUrl;
          await saveTelegramConfig(env, cfg);
          await sendTeleMessage(token, chatId, `✅ Đã cập nhật link tải App APK thành:\n<code>${apkUrl}</code>`);
        } else {
          await sendTeleMessage(token, chatId, `Cú pháp: <code>/setapk &lt;LINK_TẢI_APK&gt;</code>\nVí dụ: <code>/setapk https://github.com/.../releases</code>`);
        }
      }
    } else if (text.startsWith("/setprefix")) {
      if (isAdmin) {
        const parts = text.split(/\s+/);
        if (parts.length >= 2) {
          const pref = parts[1].trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
          if (pref) {
            cfg.order_prefix = pref;
            await saveTelegramConfig(env, cfg);
            await sendTeleMessage(token, chatId, `✅ Đã đổi tiền tố nội dung CK sang: <b>${pref}</b>\nVí dụ mã đơn khi khách mua: <code>${pref}1234</code>, <code>${pref}9899</code>`);
          } else {
            await sendTeleMessage(token, chatId, `❌ Tiền tố không hợp lệ! Vui lòng chỉ dùng chữ cái và số (VD: NAP)`);
          }
        } else {
          await sendTeleMessage(token, chatId, `Cú pháp: <code>/setprefix &lt;TIỀN_TỐ&gt;</code>\nVí dụ: <code>/setprefix NAP</code>`);
        }
      }
    } else if (text.startsWith("/setbank")) {
      if (isAdmin) {
        const parts = text.split(/\s+/);
        if (parts.length >= 4) {
          cfg.bank.bank_code = parts[1].toUpperCase();
          cfg.bank.account_no = parts[2];
          cfg.bank.account_name = parts.slice(3).join(" ").toUpperCase();
          await saveTelegramConfig(env, cfg);
          await sendTeleMessage(token, chatId, `✅ Đã cập nhật ngân hàng: ${cfg.bank.bank_code} - ${cfg.bank.account_no} - ${cfg.bank.account_name}`);
        } else {
          await sendTeleMessage(token, chatId, `Cú pháp: <code>/setbank &lt;MÃ_NH&gt; &lt;STK&gt; &lt;TÊN_CHỦ_TK&gt;</code>`);
        }
      }
    } else if (text.startsWith("/setusdt")) {
      if (isAdmin) {
        const parts = text.split(/\s+/);
        if (parts.length >= 3) {
          cfg.usdt.network = parts[1].toUpperCase();
          cfg.usdt.address = parts[2].trim();
          await saveTelegramConfig(env, cfg);
          await sendTeleMessage(token, chatId, 
            `✅ <b>ĐÃ CẬP NHẬT VÍ USDT:</b>\n\n` +
            `• Mạng: <b>${cfg.usdt.network}</b>\n` +
            `• Địa chỉ ví: <code>${cfg.usdt.address}</code>`
          );
        } else {
          await sendTeleMessage(token, chatId, `Cú pháp: <code>/setusdt &lt;MẠNG&gt; &lt;ĐỊA_CHỈ_VÍ&gt;</code>\nVí dụ: <code>/setusdt TRC20 TFxxxxxxxxxxxxxxxxxxxxxxxxx</code>`);
        }
      }
    } else if (text.startsWith("/setgiausdt")) {
      if (isAdmin) {
        const parts = text.split(/\s+/);
        if (parts.length >= 3) {
          const pkg = parts[1].toLowerCase();
          const p = parseFloat(parts[2].replace(",", "."));
          if (cfg.packages[pkg]) {
            cfg.packages[pkg].price_usdt = p;
            await saveTelegramConfig(env, cfg);
            await sendTeleMessage(token, chatId, `✅ Đã cập nhật giá USDT <b>${cfg.packages[pkg].name}</b> thành: <code>${p} USDT</code>`);
          } else {
            await sendTeleMessage(token, chatId, `❌ Không tìm thấy gói '${pkg}'! Các gói: <code>1d</code>, <code>7d</code>, <code>30d</code>, <code>90d</code>, <code>180d</code>, <code>365d</code>, <code>life</code>`);
          }
        } else {
          await sendTeleMessage(token, chatId, `Cú pháp: <code>/setgiausdt &lt;gói&gt; &lt;số_usdt&gt;</code>\nVí dụ: <code>/setgiausdt 30d 20</code>`);
        }
      }
    } else if (text.startsWith("/setgia")) {
      if (isAdmin) {
        const parts = text.split(/\s+/);
        if (parts.length >= 3) {
          const pkg = parts[1].toLowerCase();
          const p = parseInt(parts[2].replace(/[.,]/g, ""), 10);
          if (cfg.packages[pkg]) {
            cfg.packages[pkg].price = p;
            await saveTelegramConfig(env, cfg);
            await sendTeleMessage(token, chatId, `✅ Đã cập nhật giá VNĐ <b>${cfg.packages[pkg].name}</b> thành: <code>${formatVnd(p)}</code>`);
          } else {
            await sendTeleMessage(token, chatId, `❌ Không tìm thấy gói '${pkg}'! Các gói: <code>1d</code>, <code>7d</code>, <code>30d</code>, <code>90d</code>, <code>180d</code>, <code>365d</code>, <code>life</code>`);
          }
        } else {
          await sendTeleMessage(token, chatId, `Cú pháp: <code>/setgia &lt;gói&gt; &lt;số_tiền&gt;</code>\nVí dụ: <code>/setgia 30d 500000</code>`);
        }
      }
    } else if (text.startsWith("/taokey")) {
      if (isAdmin) {
        const parts = text.split(/\s+/);
        const pkg = parts.length > 1 ? parts[1].toLowerCase() : "30d";
        const key = generateRandomKey(pkg);
        
        let durSec = 30 * 86400;
        let durLabel = "30 Ngày";
        if (pkg === "1d" || pkg === "1") { durSec = 86400; durLabel = "1 Ngày"; }
        else if (pkg.includes("7")) { durSec = 7 * 86400; durLabel = "7 Ngày"; }
        else if (pkg.includes("30")) { durSec = 30 * 86400; durLabel = "30 Ngày"; }
        else if (pkg.includes("90")) { durSec = 90 * 86400; durLabel = "90 Ngày"; }
        else if (pkg.includes("180")) { durSec = 180 * 86400; durLabel = "180 Ngày"; }
        else if (pkg.includes("365") || pkg.includes("1y")) { durSec = 365 * 86400; durLabel = "365 Ngày"; }
        else if (pkg.includes("life")) { durSec = 0; durLabel = "Vĩnh viễn"; }

        const keyObj = {
          key: key,
          duration_seconds: durSec,
          duration_label: durLabel,
          note: "Tạo thủ công bởi Admin Telegram",
          bound_serial: null,
          created_at: Math.floor(Date.now() / 1000),
          status: "ACTIVE"
        };
        const { kv } = getKV(env);
        if (kv) await kv.put("key:" + key, JSON.stringify(keyObj));
        else MEMORY_KEYS[key] = keyObj;

        await sendTeleMessage(token, chatId,
          `🔑 <b>Key thủ công (${pkg.toUpperCase()}):</b>\n` +
          `👉 <code>${key}</code> 👈 (Bấm để copy)\n\n` +
          `⏳ Thời hạn: <b>${durLabel}</b>\n` +
          `<i>Key đã được lưu trực tiếp vào Cloudflare Worker và có thể kích hoạt ngay trên app.</i>`
        );
      }
    } else {
      const handled = await processTextPayment(token, cfg, env, chatId, fromUser.username, text);
      if (!handled && !isAdmin) {
        await sendTeleMessage(token, chatId, "👋 Xin chào! Vui lòng bấm /start để mở Menu hoặc chọn gói mua bản quyền nhé.");
      }
    }
  }
}

async function showStartMessage(token, cfg, env, chatId, username, firstName) {
  const adminUser = (cfg.admin_username || "").toLowerCase().replace(/^@/, "");
  const isAdmin = (username && username.toLowerCase().replace(/^@/, "") === adminUser) || (chatId && String(chatId) === String(cfg.admin_chat_id));

  if (isAdmin) {
    if (cfg.admin_chat_id !== chatId) {
      cfg.admin_chat_id = chatId;
      await saveTelegramConfig(env, cfg);
    }
    const adminText = 
      `👑 <b>XIN CHÀO QUẢN TRỊ VIÊN @${username}! (VCAM iOS)</b>\n\n` +
      `☁️ <b>Bot chạy 24/24 trên Cloudflare Workers.</b>\n` +
      `Mọi thông báo đơn hàng VNĐ & USDT sẽ gửi trực tiếp về đây để bạn duyệt.\n\n` +
      `<b>Lệnh tạo key nhanh:</b>\n` +
      `• <code>/taokey 1d</code> | <code>/taokey 7d</code>\n` +
      `• <code>/taokey 30d</code> | <code>/taokey 90d</code>\n` +
      `• <code>/taokey 180d</code> | <code>/taokey 365d</code>\n` +
      `• <code>/taokey life</code> (Vĩnh viễn)\n\n` +
      `<b>Cài đặt hệ thống:</b>\n` +
      `• <code>/setprefix NAP</code> - Tiền tố CK (VD: NAPxxxx)\n` +
      `• <code>/setbank MB STK CTK</code>\n` +
      `• <code>/setusdt TRC20 &lt;ví_usdt&gt;</code>\n` +
      `• <code>/setgia 30d 500000</code>\n` +
      `• <code>/setgiausdt 30d 20</code>\n` +
      `• <code>/caidat</code> - Xem cấu hình & bảng giá`;
    await sendTeleMessage(token, chatId, adminText);
    return;
  }

  const welcomeText = 
    `👋 Xin chào <b>${firstName || "Bạn"}</b>!\n\n` +
    `Chào mừng bạn đến với <b>Camera Assistant</b> — ` +
    `Giải pháp camera ảo chống phát hiện hàng đầu cho iOS RootHide Dopamine\n\n` +
    `✨ Hỗ trợ KYC nhận diện khuôn mặt, Livestream, giả lập camera mượt mà không delay.\n` +
    `💳 Chấp nhận thanh toán qua <b>Chuyển khoản Ngân hàng (VNĐ)</b> và <b>USDT Crypto</b>.\n\n` +
    `Vui lòng chọn chức năng bạn cần bên dưới:`;

  const keyboard = {
    inline_keyboard: [
      [{ text: "🛒 Mua Key Bản Quyền", callback_data: "menu_buy" }],
      [
        { text: "📥 Tải VCAM iOS", url: cfg.app_download_url || `https://t.me/${adminUser}` },
        { text: "📖 Hướng Dẫn Dùng", callback_data: "menu_guide" }
      ],
      [{ text: "💬 Hỗ Trợ Kỹ Thuật", url: `https://t.me/${adminUser}` }]
    ]
  };
  await sendTeleMessage(token, chatId, welcomeText, keyboard);
}

async function showMenuBuy(token, cfg, chatId) {
  const p = cfg.packages;
  const text = 
    `💎 <b>BẢNG GIÁ BẢN QUYỀN CAMERA ASSISTANT (VCAM)</b>\n\n` +
    `• <b>${p['1d'].name}:</b> <code>${formatVnd(p['1d'].price)}</code> | <code>${p['1d'].price_usdt || 2} USDT</code>\n` +
    `• <b>${p['7d'].name}:</b> <code>${formatVnd(p['7d'].price)}</code> | <code>${p['7d'].price_usdt || 7} USDT</code>\n` +
    `• <b>${p['30d'].name}:</b> <code>${formatVnd(p['30d'].price)}</code> | <code>${p['30d'].price_usdt || 20} USDT</code> 🔥\n` +
    `• <b>${p['90d'].name}:</b> <code>${formatVnd(p['90d'].price)}</code> | <code>${p['90d'].price_usdt || 48} USDT</code>\n` +
    `• <b>${p['180d'].name}:</b> <code>${formatVnd(p['180d'].price)}</code> | <code>${p['180d'].price_usdt || 84} USDT</code>\n` +
    `• <b>${p['365d'].name}:</b> <code>${formatVnd(p['365d'].price)}</code> | <code>${p['365d'].price_usdt || 144} USDT</code>\n` +
    `• <b>${p['life'].name}:</b> <code>${formatVnd(p['life'].price)}</code> | <code>${p['life'].price_usdt || 240} USDT</code> 👑\n\n` +
    `👉 <i>Vui lòng bấm chọn gói bạn muốn mua bên dưới:</i>`;

  const keyboard = {
    inline_keyboard: [
      [
        { text: `1 Ngày (${formatVnd(p['1d'].price)} / ${p['1d'].price_usdt}U)`, callback_data: "choose_1d" },
        { text: `7 Ngày (${formatVnd(p['7d'].price)} / ${p['7d'].price_usdt}U)`, callback_data: "choose_7d" }
      ],
      [
        { text: `🔥 30 Ngày (${formatVnd(p['30d'].price)} / ${p['30d'].price_usdt}U)`, callback_data: "choose_30d" },
        { text: `90 Ngày (${formatVnd(p['90d'].price)} / ${p['90d'].price_usdt}U)`, callback_data: "choose_90d" }
      ],
      [
        { text: `180 Ngày (${formatVnd(p['180d'].price)} / ${p['180d'].price_usdt}U)`, callback_data: "choose_180d" },
        { text: `365 Ngày (${formatVnd(p['365d'].price)} / ${p['365d'].price_usdt}U)`, callback_data: "choose_365d" }
      ],
      [
        { text: `💎 Vĩnh Viễn (${formatVnd(p['life'].price)} / ${p['life'].price_usdt}U)`, callback_data: "choose_life" }
      ],
      [{ text: "⬅️ Quay lại Menu chính", callback_data: "menu_back" }]
    ]
  };
  await sendTeleMessage(token, chatId, text, keyboard);
}

async function showSelectMethod(token, cfg, chatId, pkgKey) {
  const pkg = cfg.packages[pkgKey];
  if (!pkg) {
    await sendTeleMessage(token, chatId, "❌ Gói bản quyền không hợp lệ!");
    return;
  }
  const text = 
    `📦 <b>BẠN ĐÃ CHỌN: ${pkg.name.toUpperCase()}</b>\n\n` +
    `⏳ Thời hạn sử dụng: <b>${pkg.label}</b>\n` +
    `💵 Giá VNĐ: <b>${formatVnd(pkg.price)}</b>\n` +
    `🪙 Giá USDT: <b>${pkg.price_usdt || 0} USDT</b>\n\n` +
    `👉 <b>Vui lòng chọn hình thức bạn muốn thanh toán:</b>`;

  const keyboard = {
    inline_keyboard: [
      [{ text: `🏦 Chuyển khoản VNĐ (${formatVnd(pkg.price)})`, callback_data: `pay_vnd_${pkgKey}` }],
      [{ text: `🪙 Thanh toán USDT (${pkg.price_usdt || 0} USDT)`, callback_data: `pay_usdt_${pkgKey}` }],
      [{ text: "⬅️ Chọn lại gói khác", callback_data: "menu_buy" }]
    ]
  };
  await sendTeleMessage(token, chatId, text, keyboard);
}

async function processBuyVnd(token, cfg, env, chatId, username, pkgKey) {
  const order = await createTelegramOrder(env, chatId, username, pkgKey, "VND");
  if (!order) {
    await sendTeleMessage(token, chatId, "❌ Gói bản quyền không hợp lệ!");
    return;
  }
  const b = cfg.bank;
  const qrUrl = `https://img.vietqr.io/image/${b.bank_code}-${b.account_no}-compact2.png?amount=${order.price}&addInfo=${order.order_id}&accountName=${encodeURIComponent(b.account_name)}`;

  const caption = 
    `🧾 <b>ĐƠN HÀNG VNĐ: #${order.order_id}</b>\n` +
    `📦 Gói: <b>${order.package_name}</b> (${order.label})\n` +
    `💰 Số tiền: <b>${formatVnd(order.price)}</b>\n\n` +
    `🏦 <b>THÔNG TIN CHUYỂN KHOẢN:</b>\n` +
    `• Ngân hàng: <b>${b.bank_name} (${b.bank_code})</b>\n` +
    `• Số tài khoản: <code>${b.account_no}</code> (Bấm để copy)\n` +
    `• Tên chủ thẻ: <b>${b.account_name}</b>\n` +
    `• Nội dung CK (bắt buộc): <code>${order.order_id}</code>\n\n` +
    `⚠️ <b>LƯU Ý QUAN TRỌNG:</b>\n` +
    `1. Quét mã QR ở trên hoặc chuyển khoản đúng nội dung: <code>${order.order_id}</code>\n` +
    `2. Sau khi chuyển xong, <b>hãy gửi ảnh chụp màn hình biên lai (bill)</b> vào chat này.\n` +
    `3. Hệ thống sẽ xác nhận và gửi Key kích hoạt cho bạn ngay lập tức!`;

  const keyboard = {
    inline_keyboard: [
      [{ text: "❌ Hủy đơn này", callback_data: `cancel_${order.order_id}` }],
      [{ text: "💬 Hỗ Trợ Kỹ Thuật", url: `https://t.me/${cfg.admin_username}` }]
    ]
  };
  await sendTelePhoto(token, chatId, qrUrl, caption, keyboard);
}

async function processBuyUsdt(token, cfg, env, chatId, username, pkgKey) {
  const order = await createTelegramOrder(env, chatId, username, pkgKey, "USDT");
  if (!order) {
    await sendTeleMessage(token, chatId, "❌ Gói bản quyền không hợp lệ!");
    return;
  }
  const u = cfg.usdt;
  const qrUrl = `https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=${encodeURIComponent(u.address)}`;

  const caption = 
    `🧾 <b>ĐƠN HÀNG USDT: #${order.order_id}</b>\n` +
    `📦 Gói: <b>${order.package_name}</b> (${order.label})\n` +
    `💰 Số tiền cần chuyển: <b>${order.price_usdt} USDT</b>\n\n` +
    `🪙 <b>THÔNG TIN VÍ NHẬN USDT:</b>\n` +
    `• Mạng (Network): <b>${u.network}</b>\n` +
    `• Địa chỉ ví nhận:\n` +
    `<code>${u.address}</code>\n` +
    `<i>(Bấm vào địa chỉ ví ở trên để copy nhanh)</i>\n` +
    `• Ghi chú: <i>${u.note}</i>\n\n` +
    `⚠️ <b>HƯỚNG DẪN XÁC NHẬN:</b>\n` +
    `1. Chuyển chính xác <b>${order.price_usdt} USDT</b> (mạng <b>${u.network}</b>) tới ví trên.\n` +
    `2. Sau khi chuyển xong, <b>hãy gửi Mã giao dịch (TxID / Hash)</b> hoặc <b>ảnh chụp màn hình biên lai</b> vào ô chat này.\n` +
    `3. Admin sẽ kiểm tra trên Blockchain và gửi Key kích hoạt cho bạn ngay lập tức!`;

  const keyboard = {
    inline_keyboard: [
      [{ text: "❌ Hủy đơn này", callback_data: `cancel_${order.order_id}` }],
      [{ text: "💬 Hỗ Trợ Kỹ Thuật", url: `https://t.me/${cfg.admin_username}` }]
    ]
  };
  await sendTelePhoto(token, chatId, qrUrl, caption, keyboard);
}

async function processPhotoBill(token, cfg, env, chatId, username, photoFileId) {
  const userPending = await getUserPendingOrder(env, chatId);
  if (!userPending) {
    await sendTeleMessage(token, chatId,
      `⚠️ Bạn chưa có đơn hàng nào đang chờ thanh toán!\n` +
      `Vui lòng bấm /start và chọn gói bản quyền trước khi gửi ảnh biên lai nhé.`
    );
    return;
  }

  const oid = userPending.order_id;
  const method = userPending.method || "VND";
  await sendTeleMessage(token, chatId,
    `✅ <b>Đã nhận được ảnh biên lai cho đơn #${oid}!</b>\n` +
    `⏳ Admin đang kiểm tra thanh toán. Key kích hoạt sẽ được gửi trực tiếp vào đây trong 1 - 3 phút.`
  );

  const adminCid = cfg.admin_chat_id;
  if (adminCid) {
    let adminCaption = "";
    if (method === "USDT") {
      adminCaption = 
        `🔔 <b>CÓ ĐƠN HÀNG USDT CẦN DUYỆT!</b>\n\n` +
        `🧾 Mã đơn: <b>#${oid}</b>\n` +
        `👤 Khách: @${username || "N/A"} (ID: <code>${chatId}</code>)\n` +
        `📦 Gói: <b>${userPending.package_name}</b> (${userPending.label})\n` +
        `🪙 Số tiền: <b>${userPending.price_usdt || 0} USDT</b> (Mạng ${cfg.usdt.network})\n` +
        `📸 Hình thức: Ảnh chụp màn hình biên lai\n\n` +
        `👉 <i>Kiểm tra ví nhận và bấm nút bên dưới:</i>`;
    } else {
      adminCaption = 
        `🔔 <b>CÓ ĐƠN HÀNG VNĐ CẦN DUYỆT!</b>\n\n` +
        `🧾 Mã đơn: <b>#${oid}</b>\n` +
        `👤 Khách: @${username || "N/A"} (ID: <code>${chatId}</code>)\n` +
        `📦 Gói: <b>${userPending.package_name}</b> (${userPending.label})\n` +
        `💰 Số tiền: <b>${formatVnd(userPending.price)}</b>\n\n` +
        `👉 <i>Kiểm tra tài khoản ngân hàng và bấm nút bên dưới:</i>`;
    }

    const adminKb = {
      inline_keyboard: [
        [
          { text: `✅ Duyệt Cấp Key (#${oid})`, callback_data: `approve_${oid}` },
          { text: `❌ Từ Chối`, callback_data: `reject_${oid}` }
        ]
      ]
    };
    await sendTelePhoto(token, adminCid, photoFileId, adminCaption, adminKb);
  }
}

async function processTextPayment(token, cfg, env, chatId, username, text) {
  const userPending = await getUserPendingOrder(env, chatId);
  if (!userPending) return false;

  const oid = userPending.order_id;
  const method = userPending.method || "VND";
  userPending.payment_note = text;
  await saveTelegramOrder(env, userPending);

  await sendTeleMessage(token, chatId,
    `✅ <b>Đã nhận được thông tin thanh toán cho đơn #${oid}!</b>\n\n` +
    `📝 <b>Nội dung / TxID bạn gửi:</b>\n<code>${text}</code>\n\n` +
    `⏳ Admin đang kiểm tra giao dịch. Key kích hoạt sẽ được gửi trực tiếp vào đây trong 1 - 3 phút.`
  );

  const adminCid = cfg.admin_chat_id;
  if (adminCid) {
    let adminMsg = "";
    if (method === "USDT") {
      adminMsg = 
        `🔔 <b>CÓ GIAO DỊCH USDT CẦN DUYỆT! (TXID)</b>\n\n` +
        `🧾 Mã đơn: <b>#${oid}</b>\n` +
        `👤 Khách: @${username || "N/A"} (ID: <code>${chatId}</code>)\n` +
        `📦 Gói: <b>${userPending.package_name}</b> (${userPending.label})\n` +
        `🪙 Số tiền: <b>${userPending.price_usdt || 0} USDT</b> (Mạng ${cfg.usdt.network})\n\n` +
        `🔗 <b>Mã TxID / Ghi chú của khách:</b>\n` +
        `<code>${text}</code>\n\n` +
        `👉 <i>Kiểm tra ví nhận và bấm nút bên dưới:</i>`;
    } else {
      adminMsg = 
        `🔔 <b>CÓ THÔNG TIN THANH TOÁN CHO ĐƠN #${oid}!</b>\n\n` +
        `👤 Khách: @${username || "N/A"} (ID: <code>${chatId}</code>)\n` +
        `📦 Gói: <b>${userPending.package_name}</b> (${userPending.label})\n` +
        `💰 Số tiền: <b>${formatVnd(userPending.price)}</b>\n\n` +
        `📝 <b>Nội dung nhắn:</b>\n<code>${text}</code>\n\n` +
        `👉 <i>Kiểm tra tài khoản và bấm nút bên dưới:</i>`;
    }

    const adminKb = {
      inline_keyboard: [
        [
          { text: `✅ Duyệt Cấp Key (#${oid})`, callback_data: `approve_${oid}` },
          { text: `❌ Từ Chối`, callback_data: `reject_${oid}` }
        ]
      ]
    };
    await sendTeleMessage(token, adminCid, adminMsg, adminKb);
  }
  return true;
}

async function processApproveOrder(token, cfg, env, cb, orderId) {
  const order = await getTelegramOrder(env, orderId);
  if (!order) return;
  if (order.status === "COMPLETED") {
    await answerTeleCallback(token, cb.id, `Đơn #${orderId} đã được duyệt trước đó!`, true);
    return;
  }

  const pkgKey = order.package_key || "30d";
  const keyCode = generateRandomKey(pkgKey);
  order.status = "COMPLETED";
  order.key_issued = keyCode;
  order.completed_at = Math.floor(Date.now() / 1000);
  await saveTelegramOrder(env, order);

  // LƯU TRỰC TIẾP VÀO HỆ THỐNG KEY WORKER
  let durSec = 30 * 86400;
  let durLabel = order.label || "30 Ngày";
  if (order.days === 1) durSec = 86400;
  else if (order.days === 7) durSec = 7 * 86400;
  else if (order.days === 30) durSec = 30 * 86400;
  else if (order.days === 90) durSec = 90 * 86400;
  else if (order.days === 180) durSec = 180 * 86400;
  else if (order.days === 365) durSec = 365 * 86400;
  else if (order.days === 0) { durSec = 0; durLabel = "Vĩnh viễn"; }

  const keyObj = {
    key: keyCode,
    duration_seconds: durSec,
    duration_label: durLabel,
    note: `Khách @${order.customer_username || "N/A"} - Đơn #${order.order_id}`,
    bound_serial: null,
    created_at: Math.floor(Date.now() / 1000),
    status: "ACTIVE"
  };

  const { kv } = getKV(env);
  if (kv) {
    await kv.put("key:" + keyCode, JSON.stringify(keyObj));
    await kv.delete("tele_user_pending:" + order.customer_id);
  } else {
    MEMORY_KEYS[keyCode] = keyObj;
  }

  // Gửi key cho khách
  const custMsg = 
    `🎉 <b>XÁC NHẬN THANH TOÁN THÀNH CÔNG!</b>\n\n` +
    `Cảm ơn bạn đã mua bản quyền <b>Camera Assistant</b>.\n\n` +
    `🔑 <b>MÃ KÍCH HOẠT (KEY) CỦA BẠN:</b>\n` +
    `👉 <code>${keyCode}</code> 👈 (Bấm vào mã để copy)\n\n` +
    `⏳ Thời hạn: <b>${order.label}</b>\n\n` +
    `📲 <b>HƯỚNG DẪN KÍCH HOẠT:</b>\n` +
    (cfg.app_download_url ? `📥 Link tải App APK: ${cfg.app_download_url}\n` : "") +
    `1. Mở Cài đặt hoặc Tweak <b>VCAM</b> trên iPhone\n` +
    `2. Nhập mã <code>${keyCode}</code> vào ô <i>Mã bản quyền</i>\n` +
    `3. Bấm nút <b>Kích Hoạt</b> là hoàn tất sử dụng!\n\n` +
    `💬 Hỗ trợ kỹ thuật: @${cfg.admin_username}`;
  await sendTeleMessage(token, order.customer_id, custMsg);

  await answerTeleCallback(token, cb.id, `Đã duyệt đơn #${orderId} thành công!`, true);

  // Cập nhật tin nhắn Admin
  const adminName = cb.from?.username || "Admin";
  const approvedText = 
    `✅ <b>ĐÃ DUYỆT ĐƠN #${orderId}</b>\n` +
    `👤 Duyệt bởi: @${adminName}\n` +
    `🔑 Key đã cấp: <code>${keyCode}</code>\n` +
    `📦 Gói: ${order.package_name} (${order.label})\n` +
    `👤 Khách: @${order.customer_username} (ID: <code>${order.customer_id}</code>)`;

  const msg = cb.message;
  if (msg && msg.chat && msg.message_id) {
    if (msg.photo && msg.photo.length > 0) {
      await editTeleCaption(token, msg.chat.id, msg.message_id, approvedText);
    } else {
      await editTeleText(token, msg.chat.id, msg.message_id, approvedText);
    }
  }
}

async function processRejectOrder(token, cfg, env, cb, orderId) {
  const order = await getTelegramOrder(env, orderId);
  if (!order) return;
  order.status = "REJECTED";
  await saveTelegramOrder(env, order);

  await sendTeleMessage(token, order.customer_id,
    `❌ <b>Đơn hàng #${orderId} chưa thể xác nhận thanh toán!</b>\n\n` +
    `Biên lai chuyển khoản/TxID chưa hợp lệ hoặc tiền chưa vào tài khoản.\n` +
    `Vui lòng liên hệ @${cfg.admin_username} để được kiểm tra và hỗ trợ nhé.`
  );

  await answerTeleCallback(token, cb.id, `Đã từ chối đơn #${orderId}!`, true);

  const msg = cb.message;
  if (msg && msg.chat && msg.message_id) {
    const rejectedText = `❌ <b>ĐÃ TỪ CHỐI ĐƠN #${orderId}</b> (Khách: @${order.customer_username})`;
    if (msg.photo && msg.photo.length > 0) {
      await editTeleCaption(token, msg.chat.id, msg.message_id, rejectedText);
    } else {
      await editTeleText(token, msg.chat.id, msg.message_id, rejectedText);
    }
  }
}

function getDashboardHtml() {
  return `<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<title>VCAM License Manager</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Silkscreen:wght@700&display=swap" rel="stylesheet">
<style>
  :root {
    --bg: #101010;
    --dot: #1e1e1e;
    --win: #1b1b1b;
    --win2: #171717;
    --bar: #2a2a2a;
    --ink: #ececec;
    --mute: #9a9a9a;
    --line: #333;
    --ok: #3ecf6e;
    --warn: #e3a72f;
    --bad: #ff6b5e;
    --sel: #1b2e22;
    --field: #111;
  }

  /* KHÓA HOÀN TOÀN CUỘN TỔNG (CẢ DỌC LẪN NGANG) */
  *, *::before, *::after {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }
  html, body {
    width: 100%;
    height: 100%;
    overflow: hidden !important; /* KHÔNG CHO CUỘN TỔNG */
  }
  body {
    background: var(--bg) radial-gradient(var(--dot) 1px, transparent 1.2px) 0 0/6px 6px;
    color: var(--ink);
    font: 13px/1.4 "JetBrains Mono", ui-monospace, Menlo, Consolas, monospace;
    display: flex;
    justify-content: center;
    align-items: center;
    padding: 8px;
  }

  /* KHUNG CỬA SỔ CỐ ĐỊNH CHIỀU CAO VỪA KHÍT MÀN HÌNH */
  .mobile-frame {
    width: 100%;
    max-width: 440px;
    height: 96vh;
    max-height: 840px;
    background: linear-gradient(var(--win), var(--win2));
    border: 1px solid var(--line);
    border-radius: 14px;
    box-shadow: 0 16px 40px rgba(0,0,0,0.5);
    display: flex;
    flex-direction: column;
    overflow: hidden; /* Cố định tuyệt đối khung ngoài */
  }

  /* macOS Titlebar */
  .bar {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 12px;
    background: var(--bar);
    border-bottom: 1px solid var(--line);
    position: relative;
    flex-shrink: 0;
  }
  .dot { width: 10px; height: 10px; border-radius: 50%; }
  .bar .t {
    position: absolute; left: 0; right: 0;
    text-align: center; color: var(--mute);
    font-size: 11px; pointer-events: none;
  }

  /* PHẦN CỐ ĐỊNH TRÊN CÙNG: KHÔNG CUỘN, LUÔN ĐỨNG YÊN */
  .fixed-top {
    flex-shrink: 0;
    padding: 12px 14px 6px;
  }
  .logo {
    font: 700 28px/1 Silkscreen, monospace;
    letter-spacing: .03em;
    text-align: center;
    margin: 2px 0 3px;
  }
  .sub {
    text-align: center;
    color: var(--mute);
    font-size: 11px;
    margin-bottom: 12px;
  }

  .cmd {
    font-weight: 700;
    margin: 8px 0 4px;
    font-size: 12px;
  }
  .cmd i {
    color: var(--ok);
    font-style: normal;
    margin-right: 6px;
  }

  /* Stats grid gọn gàng */
  .kv {
    display: grid;
    grid-template-columns: 86px 1fr;
    row-gap: 2px;
    font-size: 11.5px;
    padding-left: 6px;
  }
  .kv span:nth-child(odd) { color: var(--mute); }
  .ok { color: var(--ok); font-weight: 600; }
  .bad { color: var(--bad); font-weight: 600; }
  .warn { color: var(--warn); font-weight: 600; }

  .create-link {
    display: inline-block;
    color: var(--ink);
    padding-left: 6px;
    text-decoration: none;
    font-weight: 600;
    cursor: pointer;
    font-size: 11.5px;
  }
  .create-link:hover { color: var(--ok); }

  /* Form tạo key trượt mở */
  .form-wrap {
    background: #141414;
    border: 1px solid var(--line);
    border-radius: 8px;
    padding: 10px;
    margin: 6px 0 8px;
  }
  .pkg-btns {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-bottom: 8px;
  }
  .pkg-btns button {
    background: #1f1f1f;
    border: 1px solid var(--line);
    color: var(--mute);
    padding: 4px 8px;
    border-radius: 4px;
    font-family: inherit;
    font-size: 10.5px;
    cursor: pointer;
  }
  .pkg-btns button.on {
    background: var(--sel);
    border-color: var(--ok);
    color: var(--ok);
    font-weight: 700;
  }
  .input-grid {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 6px;
  }
  .input-grid input, .input-grid select {
    background: var(--field);
    border: 1px solid var(--line);
    border-radius: 4px;
    color: var(--ink);
    font-family: inherit;
    font-size: 11px;
    padding: 5px 8px;
    width: 100%;
  }
  .go-btn {
    grid-column: 1 / -1;
    background: var(--ok);
    color: #08130c;
    border: none;
    border-radius: 4px;
    padding: 7px;
    font-family: inherit;
    font-weight: 700;
    font-size: 11.5px;
    cursor: pointer;
    margin-top: 4px;
  }
  .go-btn:hover { opacity: 0.9; }

  /* Ô tìm kiếm */
  .search-input {
    width: 100%;
    padding: 6px 10px;
    border-radius: 6px;
    border: 1px solid var(--line);
    background: var(--field);
    color: var(--ink);
    font-family: inherit;
    font-size: 11px;
    margin: 6px 0 4px 0;
  }
  .search-input:focus {
    outline: 1px solid var(--ok);
  }

  /* Tabs bộ lọc - Gập dòng tự nhiên, KHÔNG scroll ngang */
  .filter-grid {
    display: flex;
    flex-wrap: wrap;
    gap: 3px 8px;
    padding: 2px 0 6px 0;
    border-bottom: 1px solid var(--line);
  }
  .filter-grid button {
    background: none;
    border: none;
    color: var(--mute);
    font-family: inherit;
    font-size: 11px;
    padding: 2px 2px;
    cursor: pointer;
    flex-shrink: 0;
  }
  .filter-grid button.on {
    color: var(--ink);
    font-weight: 700;
    text-decoration: underline;
    text-decoration-color: var(--ok);
    text-underline-offset: 3px;
    text-decoration-thickness: 2px;
  }

  /* KHU VỰC DUY NHẤT ĐƯỢC PHÉP CUỘN: DANH SÁCH KEY (FLEX: 1) */
  .key-scroll-section {
    flex: 1;
    min-height: 0; /* Cho phép flexbox cuộn nội bộ chuẩn xác */
    margin: 6px 14px 10px;
    border: 1px solid var(--line);
    border-radius: 8px;
    background: var(--field);
    overflow-y: auto;   /* CHỈ CUỘN DỌC TRONG KHUNG NÀY */
    overflow-x: hidden; /* TUYỆT ĐỐI KHÔNG CUỘN NGANG */
    -webkit-overflow-scrolling: touch;
  }

  /* Tùy chỉnh thanh cuộn Dark Mode */
  .key-scroll-section::-webkit-scrollbar {
    width: 6px;
  }
  .key-scroll-section::-webkit-scrollbar-track {
    background: var(--field);
  }
  .key-scroll-section::-webkit-scrollbar-thumb {
    background: #333;
    border-radius: 4px;
  }
  .key-scroll-section::-webkit-scrollbar-thumb:hover {
    background: var(--ok);
  }

  /* Từng hàng Key */
  .key-row {
    padding: 9px 10px;
    border-bottom: 1px solid var(--line);
    cursor: pointer;
    width: 100%;
    transition: background 0.1s;
  }
  .key-row:last-child { border-bottom: none; }
  .key-row:hover, .key-row.open { background: var(--sel); }
  
  .row-top {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 6px;
    margin-bottom: 2px;
  }
  .key-code {
    font-weight: 700;
    font-size: 11.5px;
    color: var(--ink);
    word-break: break-all;
  }
  .key-status {
    font-size: 10px;
    font-weight: 600;
    white-space: nowrap;
    flex-shrink: 0;
  }
  
  .row-bot {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 6px;
    font-size: 10.5px;
    color: var(--mute);
  }
  .row-bot span:first-child {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .row-bot span:last-child {
    white-space: nowrap;
    flex-shrink: 0;
  }

  /* Khối chi tiết bung mở khi nhấp xem */
  .key-detail {
    background: var(--sel);
    padding: 8px 6px;
    border-top: 1px dashed var(--line);
    font-size: 10.5px;
    display: grid;
    grid-template-columns: 66px 1fr;
    row-gap: 3px;
    word-break: break-all;
    margin-top: 6px;
  }
  .detail-acts {
    grid-column: 1 / -1;
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 5px;
    margin-top: 6px;
  }
  .detail-acts button {
    background: var(--win);
    border: 1px solid var(--line);
    border-radius: 4px;
    padding: 5px 2px;
    font-family: inherit;
    font-size: 10px;
    font-weight: 600;
    color: var(--ink);
    cursor: pointer;
    text-align: center;
  }
  .detail-acts button:hover {
    border-color: var(--ok);
    color: var(--ok);
  }
  .detail-acts button.del-btn {
    color: var(--bad);
  }

  /* Footer cố định nhỏ */
  .fixed-bottom {
    flex-shrink: 0;
    text-align: center;
    font-size: 9.5px;
    color: var(--mute);
    padding: 0 12px 8px;
  }

  /* Toast */
  .toast {
    position: fixed;
    bottom: 20px;
    left: 50%;
    transform: translateX(-50%) translateY(20px);
    background: var(--ink);
    color: var(--bg);
    padding: 8px 14px;
    border-radius: 6px;
    font-size: 11px;
    font-weight: 600;
    opacity: 0;
    pointer-events: none;
    transition: all 0.2s;
    z-index: 100;
  }
  .toast.show {
    transform: translateX(-50%) translateY(0);
    opacity: 1;
  }
</style>
</head>
<body>

<div class="mobile-frame">
  <!-- 1. macOS Titlebar (Cố định) -->
  <div class="bar">
    <span class="dot" style="background:#ff5f57"></span>
    <span class="dot" style="background:#febc2e"></span>
    <span class="dot" style="background:#28c840"></span>
    <span class="t">vcam-license</span>
  </div>

  <!-- 2. PHẦN CỐ ĐỊNH TRÊN CÙNG: KHÔNG CUỘN, LUÔN ĐỨNG YÊN -->
  <div class="fixed-top">
    <div class="logo">VCAM</div>
    <div class="sub">Quản lý license iOS · Cloudflare Worker</div>

    <!-- Status -->
    <div class="cmd"><i>$</i>vcam status</div>
    <div class="kv" id="statsArea">
      <!-- Cập nhật tự động qua JS -->
    </div>

    <!-- Create link -->
    <div class="cmd"><i>$</i>vcam create</div>
    <a class="create-link" id="toggleCreateBtn" onclick="toggleCreateForm()">&gt; Tạo key mới (gói 30d, 90d, vĩnh viễn...)</a>

    <!-- Form tạo key ẩn/hiện -->
    <div id="createFormWrap" class="form-wrap" style="display: none;">
      <div class="pkg-btns" id="pkgSelector">
        <button data-dur="30" class="on">30 ngày</button>
        <button data-dur="90">90 ngày</button>
        <button data-dur="365">365 ngày</button>
        <button data-dur="0">Vĩnh viễn</button>
        <button data-dur="1">1 ngày (test)</button>
      </div>
      <div class="input-grid">
        <input type="text" id="newBuyer" placeholder="Tên khách / Người mua">
        <select id="newPlat">
          <option>Zalo</option>
          <option>Telegram</option>
          <option>Facebook</option>
          <option>Khác</option>
        </select>
        <input type="text" id="newPrefix" value="VCAM" placeholder="Prefix" maxlength="6">
        <input type="text" id="newNote" placeholder="Ghi chú">
        <button class="go-btn" onclick="submitCreateKey()">⚡ Tạo và lưu key</button>
      </div>
    </div>

    <!-- Keys List Header -->
    <div class="cmd"><i>$</i>vcam keys --list</div>

    <!-- Ô tìm kiếm -->
    <input type="search" id="searchInput" class="search-input" placeholder="Tìm key, người mua, HWID, ghi chú…" oninput="filterAndRender()">

    <!-- Bộ lọc Wrap không scroll ngang -->
    <div class="filter-grid" id="filterTabs">
      <!-- Cập nhật tự động qua JS -->
    </div>
  </div>

  <!-- 3. VÙNG DUY NHẤT CUỘN: DANH SÁCH KEY (CHỈ CUỘN DỌC TẠI ĐÂY) -->
  <div class="key-scroll-section" id="keysListContainer">
    <!-- Render bởi JS -->
  </div>

  <!-- 4. Ghi chú dưới cùng cố định -->
  <div class="fixed-bottom">
    ↕ Chỉ cuộn danh sách key ở trên • Cố định toàn trang • Không cuộn ngang
  </div>
</div>

<div id="toast" class="toast"></div>

<script>
  let data = [];
  let activeFilter = 'all';
  let openKey = null;
  let selectedDur = 30;

  function showToast(msg) {
    const t = document.getElementById('toast');
    t.innerText = msg;
    t.classList.add('show');
    clearTimeout(t.timer);
    t.timer = setTimeout(() => { t.classList.remove('show'); }, 3000);
  }

  function copyText(txt) {
    navigator.clipboard.writeText(txt).then(() => {
      showToast('Đã copy: ' + txt);
    }).catch(() => {
      showToast(txt);
    });
  }

  // TẢI DỮ LIỆU KEY TRỰC TIẾP TỪ CLOUDFLARE KV
  async function loadLiveKeys() {
    try {
      const res = await fetch('/api/admin/devices');
      if (res.status === 401) {
        window.location.href = '/a';
        return;
      }
      const resJson = await res.json();
      if (!resJson.success) {
        showToast('Lỗi: ' + (resJson.error || 'Không thể lấy dữ liệu'));
        return;
      }

      const rawList = resJson.keys || [];
      const nowMs = Date.now();

      data = rawList.map(k => {
        const rawSt = (k.status || '').toLowerCase();
        let exp = k.expires_at;
        if (exp && exp > 0 && exp < 1e11) exp *= 1000;

        let created = k.created_at || (nowMs - 86400000);
        if (created && created < 1e11) created *= 1000;

        let durLabel = '30 ngày';
        if (k.duration_days === 0 || k.duration_seconds === 0) durLabel = 'Vĩnh viễn';
        else if (k.duration_days) durLabel = k.duration_days + ' ngày';
        else if (k.duration_label) durLabel = k.duration_label;

        const devs = k.devices || [];
        let hwid = k.bound_serial || k.hwid;
        let devModel = k.device_model || 'iPhone';
        if (devs && devs.length > 0) {
          hwid = devs[0].hwid || hwid;
          devModel = devs[0].device_name || devModel;
        }

        const snShort = hwid ? (hwid.substring(0, 8) + '…') : 'chưa gắn';
        const isLocked = (rawSt === 'revoked' || rawSt === 'banned' || rawSt === 'locked');
        let st = isLocked ? 'locked' : ((exp && exp < nowMs) ? 'expired' : 'active');

        return {
          key: k.key,
          buyer: k.buyer_name || k.note || k.sub_note || 'Khách hàng',
          plat: k.social_platform || 'Zalo',
          acct: k.social_account || '',
          dur_label: durLabel,
          duration_days: k.duration_days !== undefined ? k.duration_days : 30,
          created: created,
          exp: exp,
          dev: hwid ? devModel : '—',
          sn: snShort,
          ip: k.last_ip || '—',
          loc: k.location || k.last_location || '—',
          st: st,
          note: k.note || ''
        };
      });

      updateStats();
      filterAndRender();
    } catch (e) {
      console.error('loadLiveKeys error:', e);
      showToast('Lỗi nạp dữ liệu: ' + e.message);
    }
  }

  // Xác định trạng thái key
  function getStatus(k) {
    if (k.st === 'locked') return 'locked';
    if (!k.exp) return 'active';
    const now = Date.now();
    if (k.exp < now) return 'expired';
    if (k.exp - now < 3 * 86400000) return 'soon';
    return 'active';
  }

  // Nhãn hiển thị trạng thái
  function getStatusBadge(k) {
    const s = getStatus(k);
    if (s === 'locked') return '<span class="key-status bad">Đã khóa</span>';
    if (s === 'expired') return '<span class="key-status bad">Hết hạn</span>';
    if (s === 'soon') {
      const daysLeft = Math.max(1, Math.ceil((k.exp - Date.now()) / 86400000));
      return '<span class="key-status warn">Sắp hết (còn ' + daysLeft + 'd)</span>';
    }
    return '<span class="key-status ok">Đang chạy</span>';
  }

  // Cập nhật thống kê
  function updateStats() {
    let total = data.length;
    let running = 0, soon = 0, expired = 0, locked = 0;

    data.forEach(k => {
      const s = getStatus(k);
      if (s === 'locked') locked++;
      else if (s === 'expired') expired++;
      else if (s === 'soon') soon++;
      else running++;
    });

    const statsEl = document.getElementById('statsArea');
    if (statsEl) {
      statsEl.innerHTML = 
        '<span>tổng key</span><span>' + total + '</span>' +
        '<span>đang chạy</span><span class="ok">' + (running + soon) + '</span>' +
        '<span>sắp hết</span><span class="warn">' + soon + '</span>' +
        '<span>hết hạn</span><span class="bad">' + expired + '</span>' +
        '<span>đã khóa</span><span class="bad">' + locked + '</span>' +
        '<span>quy tắc</span><span>1 key = 1 thiết bị</span>';
    }

    const tabsEl = document.getElementById('filterTabs');
    if (tabsEl) {
      tabsEl.innerHTML = 
        '<button class="' + (activeFilter === 'all' ? 'on' : '') + '" onclick="setFilter(\\'all\\')">Tất cả (' + total + ')</button>' +
        '<button class="' + (activeFilter === 'expired' ? 'on' : '') + '" style="color:var(--bad); font-weight:600;" onclick="setFilter(\\'expired\\')">Hết hạn (' + expired + ')</button>' +
        '<button class="' + (activeFilter === 'soon' ? 'on' : '') + '" style="color:var(--warn); font-weight:600;" onclick="setFilter(\\'soon\\')">Sắp hết (' + soon + ')</button>' +
        '<button class="' + (activeFilter === 'active' ? 'on' : '') + '" style="color:var(--ok);" onclick="setFilter(\\'active\\')">Đang chạy (' + (running + soon) + ')</button>' +
        '<button class="' + (activeFilter === 'locked' ? 'on' : '') + '" onclick="setFilter(\\'locked\\')">Đã khóa (' + locked + ')</button>';
    }
  }

  // SẮP XẾP ƯU TIÊN: HẾT HẠN & KHÓA LÊN ĐẦU TIÊN -> SẮP HẾT -> ĐANG CHẠY
  function sortKeys(list) {
    const rank = { 'expired': 1, 'locked': 2, 'soon': 3, 'active': 4 };
    return [...list].sort((a, b) => {
      return (rank[getStatus(a)] || 9) - (rank[getStatus(b)] || 9);
    });
  }

  // RENDER DANH SÁCH KEY
  function filterAndRender() {
    const q = (document.getElementById('searchInput').value || '').toLowerCase().trim();

    let filtered = data.filter(k => {
      const s = getStatus(k);
      if (activeFilter === 'expired' && s !== 'expired') return false;
      if (activeFilter === 'soon' && s !== 'soon') return false;
      if (activeFilter === 'active' && s !== 'active' && s !== 'soon') return false;
      if (activeFilter === 'locked' && s !== 'locked') return false;

      if (q) {
        const str = [k.key, k.buyer, k.plat, k.acct, k.dev, k.sn, k.ip, k.note].join(' ').toLowerCase();
        if (!str.includes(q)) return false;
      }
      return true;
    });

    filtered = sortKeys(filtered);

    const container = document.getElementById('keysListContainer');
    if (!container) return;

    if (filtered.length === 0) {
      container.innerHTML = '<div style="text-align:center; padding:24px; color:var(--mute); font-size:11px;">Không có mã key nào khớp</div>';
      return;
    }

    container.innerHTML = filtered.map(k => {
      const isOpen = (openKey === k.key);
      const s = getStatus(k);
      let rowBg = '';
      if (s === 'expired' || s === 'locked') rowBg = 'background: rgba(239, 68, 68, 0.05);';
      else if (s === 'soon') rowBg = 'background: rgba(245, 158, 11, 0.07);';

      const expDateStr = k.exp ? new Date(k.exp).toLocaleDateString('vi-VN') : 'Vĩnh viễn';
      const daysLeftStr = k.exp ? (Math.ceil((k.exp - Date.now()) / 86400000) + 'd') : '';

      return '<div class="key-row' + (isOpen ? ' open' : '') + '" style="' + rowBg + '" onclick="toggleKey(\\'' + k.key + '\\', event)">' +
        '<div class="row-top">' +
          '<span class="key-code">' + (isOpen ? '&gt; ' : '') + k.key + '</span>' +
          getStatusBadge(k) +
        '</div>' +
        '<div class="row-bot">' +
          '<span>' + k.buyer + ' · ' + k.dev + '</span>' +
          '<span>' + k.dur_label + (k.exp && s === 'active' ? ' (còn ' + daysLeftStr + ')' : '') + '</span>' +
        '</div>' +
        (isOpen ? renderDetail(k, s, expDateStr) : '') +
      '</div>';
    }).join('');
  }

  function renderDetail(k, s, expDateStr) {
    return '<div class="key-detail" onclick="event.stopPropagation()">' +
      '<span style="color:var(--mute)">liên kết</span><span>' + (k.plat ? (k.plat + ': ' + (k.acct || k.buyer)) : k.buyer) + '</span>' +
      '<span style="color:var(--mute)">thiết bị</span><span>' + k.dev + ' (' + k.sn + ')</span>' +
      '<span style="color:var(--mute)">hạn dùng</span><span class="' + (s === 'expired' || s === 'locked' ? 'bad' : (s === 'soon' ? 'warn' : 'ok')) + '">' + expDateStr + (k.exp ? (' · ' + (s === 'expired' ? 'Quá hạn' : 'Hết hạn sau ' + Math.ceil((k.exp - Date.now()) / 86400000) + ' ngày')) : '') + '</span>' +
      '<span style="color:var(--mute)">ip / vị trí</span><span>' + (k.ip || '—') + ' · ' + (k.loc || '—') + '</span>' +
      (k.note ? '<span style="color:var(--mute)">ghi chú</span><span>' + k.note + '</span>' : '') +
      '<div class="detail-acts">' +
        '<button onclick="copyText(\\'' + k.key + '\\')">Copy key</button>' +
        '<button style="color:var(--warn)" onclick="extendKey(\\'' + k.key + '\\')">+ Gia hạn 30d</button>' +
        '<button onclick="resetDevice(\\'' + k.key + '\\')">Reset máy</button>' +
        (s === 'locked' 
          ? '<button style="color:var(--ok)" onclick="toggleLock(\\'' + k.key + '\\')">Mở khóa</button>' 
          : '<button class="del-btn" onclick="toggleLock(\\'' + k.key + '\\')">Khóa key</button>') +
        '<button class="del-btn" style="grid-column: 1 / -1;" onclick="deleteKey(\\'' + k.key + '\\')">Xóa vĩnh viễn</button>' +
      '</div>' +
    '</div>';
  }

  function toggleKey(key, event) {
    if (event.target.tagName === 'BUTTON') return;
    openKey = (openKey === key) ? null : key;
    filterAndRender();
  }

  function setFilter(f) {
    activeFilter = f;
    updateStats();
    filterAndRender();
  }

  function toggleCreateForm() {
    const w = document.getElementById('createFormWrap');
    w.style.display = (w.style.display === 'none') ? 'block' : 'none';
  }

  // Chọn gói khi tạo key
  document.getElementById('pkgSelector').onclick = (e) => {
    const btn = e.target.closest('button');
    if (!btn) return;
    document.querySelectorAll('#pkgSelector button').forEach(b => b.classList.remove('on'));
    btn.classList.add('on');
    selectedDur = parseInt(btn.dataset.dur);
  };

  async function submitCreateKey() {
    const buyer = document.getElementById('newBuyer').value.trim() || 'Khách mới';
    const plat = document.getElementById('newPlat').value;
    const pfx = (document.getElementById('newPrefix').value || 'VCAM').trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
    const note = document.getElementById('newNote').value.trim();

    try {
      showToast('Đang tạo mã key trên Cloudflare KV...');
      const res = await fetch('/api/admin/create-key', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          duration_type: selectedDur === 0 ? 'lifetime' : 'days',
          duration_val: selectedDur,
          duration_label: selectedDur === 0 ? 'Vĩnh viễn' : (selectedDur + ' Ngày'),
          price: 0,
          buyer_name: buyer,
          social_platform: plat,
          note: note,
          prefix: pfx
        })
      });
      const data = await res.json();
      if (data.success && data.key) {
        showToast('Đã tạo thành công key: ' + data.key.key);
        document.getElementById('newBuyer').value = '';
        document.getElementById('newNote').value = '';
        document.getElementById('createFormWrap').style.display = 'none';
        openKey = data.key.key;
        await loadLiveKeys();
      } else {
        alert('Lỗi tạo key: ' + (data.error || 'Không xác định'));
      }
    } catch (e) {
      alert('Lỗi kết nối API: ' + e.message);
    }
  }

  async function toggleLock(key) {
    const k = data.find(x => x.key === key);
    if (!k) return;
    const isLocked = (k.st === 'locked');
    const action = isLocked ? 'restore' : 'revoke';
    if (!confirm('Bạn có chắc muốn ' + (isLocked ? 'MỞ KHÓA' : 'KHÓA') + ' key ' + key + '?')) return;

    try {
      const res = await fetch('/api/admin/key-action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, key })
      });
      const resJson = await res.json();
      if (resJson.success) {
        showToast(resJson.message);
        await loadLiveKeys();
      } else {
        alert('Lỗi: ' + (resJson.error || ''));
      }
    } catch (e) {
      alert('Lỗi kết nối: ' + e.message);
    }
  }

  async function resetDevice(key) {
    if (!confirm('Xác nhận gỡ thiết bị cho key ' + key + '? Khách có thể kích hoạt trên máy mới.')) return;
    try {
      const res = await fetch('/api/admin/key-action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'reset-device', key })
      });
      const resJson = await res.json();
      if (resJson.success) {
        showToast(resJson.message);
        await loadLiveKeys();
      } else {
        alert('Lỗi: ' + (resJson.error || ''));
      }
    } catch (e) {
      alert('Lỗi kết nối: ' + e.message);
    }
  }

  async function extendKey(key) {
    alert('Để gia hạn key, bạn có thể chỉnh ngày hoặc cấp key mới.');
  }

  async function deleteKey(key) {
    if (!confirm('⚠️ CẢNH BÁO: Xóa vĩnh viễn key ' + key + ' khỏi cơ sở dữ liệu?')) return;
    try {
      const res = await fetch('/api/admin/key-action', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'delete', key })
      });
      const resJson = await res.json();
      if (resJson.success) {
        showToast(resJson.message);
        openKey = null;
        await loadLiveKeys();
      } else {
        alert('Lỗi: ' + (resJson.error || ''));
      }
    } catch (e) {
      alert('Lỗi kết nối: ' + e.message);
    }
  }

  // Khởi chạy khi tải trang
  loadLiveKeys();

</script>
</body>
</html>`;
}

function getLoginHtml() {
  return `<!DOCTYPE html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<title>Đăng Nhập Quản Trị - VCAM Server</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600;700;800&family=Silkscreen:wght@700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
<style>
  :root {
    --bg: #101010;
    --dot: #1e1e1e;
    --win: #1b1b1b;
    --win2: #171717;
    --bar: #2a2a2a;
    --ink: #ececec;
    --mute: #9a9a9a;
    --line: #333;
    --ok: #3ecf6e;
    --warn: #e3a72f;
    --bad: #ff6b5e;
    --sel: #1b2e22;
    --field: #111;
  }

  *, *::before, *::after {
    box-sizing: border-box;
    margin: 0;
    padding: 0;
  }

  html, body {
    width: 100%;
    min-height: 100vh;
    background: var(--bg) radial-gradient(var(--dot) 1px, transparent 1.2px) 0 0/6px 6px;
    color: var(--ink);
    font: 13px/1.4 "JetBrains Mono", ui-monospace, Menlo, Consolas, monospace;
    display: flex;
    justify-content: center;
    align-items: center;
    padding: 8px;
  }

  /* KHUNG CỬA SỔ macOS ĐỒNG BỘ 100% VỚI TRANG QUẢN TRỊ (MAX-WIDTH: 440PX) */
  .mobile-frame {
    width: 100%;
    max-width: 440px;
    background: linear-gradient(var(--win), var(--win2));
    border: 1px solid var(--line);
    border-radius: 14px;
    box-shadow: 0 16px 40px rgba(0,0,0,0.5);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  /* macOS Titlebar đồng bộ kích thước */
  .bar {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 8px 12px;
    background: var(--bar);
    border-bottom: 1px solid var(--line);
    position: relative;
    flex-shrink: 0;
    user-select: none;
  }
  .dot { width: 10px; height: 10px; border-radius: 50%; }
  .bar .t {
    position: absolute; left: 0; right: 0;
    text-align: center; color: var(--mute);
    font-size: 11px; pointer-events: none;
  }

  /* Thân form đồng bộ padding */
  .form-body {
    padding: 16px 14px 22px;
    display: flex;
    flex-direction: column;
  }

  /* Logo Silkscreen đồng bộ 28px */
  .logo {
    font: 700 28px/1 Silkscreen, monospace;
    letter-spacing: .03em;
    text-align: center;
    margin: 2px 0 3px;
    color: #fff;
  }

  /* Subtitle đồng bộ 11px */
  .sub {
    text-align: center;
    color: var(--mute);
    font-size: 11px;
    margin-bottom: 14px;
  }

  /* Dòng lệnh cmd $ đồng bộ 12px */
  .cmd {
    font-weight: 700;
    margin: 6px 0 14px;
    font-size: 12px;
  }
  .cmd i {
    color: var(--ok);
    font-style: normal;
    margin-right: 6px;
  }

  /* Nhóm nhập liệu */
  .form-group {
    display: flex;
    flex-direction: column;
    gap: 5px;
    margin-bottom: 12px;
  }

  .form-group label {
    font-size: 11.5px;
    font-weight: 600;
    color: var(--mute);
    padding-left: 2px;
  }

  .form-control {
    width: 100%;
    background: var(--field);
    border: 1px solid var(--line);
    border-radius: 6px;
    padding: 8px 10px;
    color: var(--ink);
    font-family: inherit;
    font-size: 11.5px;
    outline: none;
    transition: all 0.15s;
  }

  .form-control:focus {
    border-color: var(--ok);
    outline: 1px solid var(--ok);
  }

  /* Ô nhập OTP 2FA */
  input.otp-input {
    font-size: 18px;
    letter-spacing: 8px;
    text-align: center;
    font-weight: 700;
    color: var(--ok);
    background: #0d0d0d;
    padding: 8px 10px;
  }

  /* Nút đăng nhập Relaxin Green đồng bộ style */
  .btn-submit {
    width: 100%;
    background: var(--ok);
    color: #08130c;
    border: none;
    border-radius: 6px;
    padding: 10px;
    font-family: inherit;
    font-weight: 700;
    font-size: 12.5px;
    cursor: pointer;
    margin-top: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    transition: all 0.15s;
  }

  .btn-submit:hover {
    opacity: 0.92;
    transform: translateY(-1px);
  }

  .btn-submit:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  /* Thông báo lỗi */
  .error-box {
    background: rgba(255, 107, 94, 0.1);
    border: 1px solid var(--bad);
    color: var(--bad);
    padding: 8px 10px;
    border-radius: 6px;
    font-size: 11px;
    margin-bottom: 12px;
    display: none;
    align-items: center;
    gap: 6px;
  }
</style>
</head>
<body>

<div class="mobile-frame">
  <!-- macOS Titlebar đồng bộ -->
  <div class="bar">
    <span class="dot" style="background:#ff5f57"></span>
    <span class="dot" style="background:#febc2e"></span>
    <span class="dot" style="background:#28c840"></span>
    <span class="t">vcam-admin</span>
  </div>

  <div class="form-body">
    <div class="logo">VCAM</div>
    <div class="sub">Quản trị server iOS · xác thực 2 lớp (2FA)</div>

    <div class="cmd"><i>$</i>vcam login</div>

    <div id="errMsg" class="error-box">
      <i class="fa-solid fa-triangle-exclamation"></i>
      <span id="errText">Mật khẩu hoặc mã 2FA không chính xác!</span>
    </div>

    <form id="loginForm" onsubmit="handleLogin(event)">
      <div class="form-group">
        <label>Tên đăng nhập</label>
        <input type="text" id="username" class="form-control" value="admin" required autocomplete="username">
      </div>

      <div class="form-group">
        <label>Mật khẩu</label>
        <input type="password" id="password" class="form-control" placeholder="Nhập mật khẩu" required autocomplete="current-password">
      </div>

      <div class="form-group">
        <label>Mã 2FA Google Authenticator (6 số)</label>
        <input type="text" id="otp" class="form-control otp-input" maxlength="6" pattern="[0-9]{6}" inputmode="numeric" required placeholder="000000" autocomplete="one-time-code">
      </div>

      <button type="submit" id="btnLogin" class="btn-submit">
        Đăng nhập
      </button>
    </form>
  </div>
</div>

<script>
  async function handleLogin(e) {
    e.preventDefault();
    const btn = document.getElementById('btnLogin');
    const errBox = document.getElementById('errMsg');
    const errText = document.getElementById('errText');

    errBox.style.display = 'none';
    btn.disabled = true;
    btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> Đang xác thực...';

    const u = document.getElementById('username').value.trim();
    const p = document.getElementById('password').value;
    const otp = document.getElementById('otp').value.trim();

    try {
      const res = await fetch('/api/admin/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: u, password: p, otp: otp })
      });
      const data = await res.json();
      if (data.success) {
        window.location.href = '/a';
      } else {
        errText.innerText = data.error || 'Sai tên đăng nhập, mật khẩu hoặc mã 2FA!';
        errBox.style.display = 'flex';
      }
    } catch (err) {
      errText.innerText = 'Lỗi kết nối máy chủ: ' + err.message;
      errBox.style.display = 'flex';
    } finally {
      btn.disabled = false;
      btn.innerHTML = 'Đăng nhập';
    }
  }
</script>

</body>
</html>
`;
}
