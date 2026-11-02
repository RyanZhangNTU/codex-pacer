const stored = (key) => {
  const raw = localStorage.getItem(key);
  if (raw == null) return null;
  try { const value = JSON.parse(raw); return value && typeof value === 'object' && 'value' in value ? value.value : value; }
  catch (error) { return raw; }
};
const token = stored('userToken');
if (typeof token !== 'string' || token.length < 8) return { state: 'signedOut' };
let response;
try {
  response = await fetch('/api/v0/users/get_user_summary', { credentials: 'include', cache: 'no-store',
    headers: { 'Authorization': 'Bearer ' + token, 'x-client-platform': 'web', 'x-client-version': '1.0.0' } });
} catch (error) { return { state: 'offline' }; }
if (response.headers.get('x-amzn-waf-action')) return { state: 'challenge' };
if (response.status === 401) return { state: 'signedOut' };
let body;
try { body = await response.json(); } catch (error) { return { state: 'invalid' }; }
const code = body && (body.code || (body.data && body.data.biz_code));
if (code === 40002 || code === 40003) return { state: 'signedOut' };
const data = body && body.data && body.data.biz_data;
if (!data) return { state: 'invalid' };
const wallets = (list) => (Array.isArray(list) ? list : []);
const cny = (list) => wallets(list).filter((w) => w && w.currency === 'CNY').map((w) => String(w.balance));
const other = wallets(data.normal_wallets).concat(wallets(data.bonus_wallets)).some((w) => w && w.currency && w.currency !== 'CNY');
const info = stored('__appKit_userInfo');
const alert = info && info.balanceAlert && info.balanceAlert.CNY;
return { state: 'ok', normal: cny(data.normal_wallets), bonus: cny(data.bonus_wallets), otherCurrency: other,
  estimation: data.total_available_token_estimation == null ? null : String(data.total_available_token_estimation),
  alertEnabled: !!(alert && alert.enabled), alertBound: alert && alert.alertBound != null ? String(alert.alertBound) : null };
