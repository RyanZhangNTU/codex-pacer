const raw = localStorage.getItem('userToken');
if (raw == null) return null;
let token = raw;
try { const value = JSON.parse(raw); token = value && typeof value === 'object' ? value.value : value; } catch (error) {}
if (typeof token !== 'string' || token.length < 8) return null;
const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)));
return Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
