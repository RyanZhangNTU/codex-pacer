// Runs in Pacer's own signed-in browser profile. Only the display values leave the browser.
const origin = new URL(document.baseURI).origin;
if (origin !== "https://www.workbuddy.cn" && origin !== "https://www.workbuddy.ai") return { state: "unavailable" };

const amount = value => {
    if (typeof value === "string" && /^(?:[0-9]+)(?:\.[0-9]+)?$/.test(value)) value = Number(value);
    return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1e12 ? value : null;
};

const readJSON = async response => {
    if (response.status !== 200 || !response.headers.get("content-type")?.includes("application/json")) return null;
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let bytes = 0, body = "";
    while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.length;
        if (bytes > 262144) {
            await reader.cancel();
            return null;
        }
        body += decoder.decode(value, { stream: true });
    }
    return JSON.parse(body + decoder.decode());
};

const request = (resource, body, signal) => fetch(origin + "/billing/meter/get-user-resource-" + resource, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
    credentials: "same-origin", redirect: "error", cache: "no-store", signal,
});

const timestamp = value => {
    if (typeof value === "number" || typeof value === "string" && /^\d{13}$/.test(value)) return Number(value) / 1000;
    if (typeof value !== "string") return NaN;
    const local = /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(value) && origin.endsWith(".cn") ? value + "+08:00" : value;
    return /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/.test(local)
        ? Date.parse(local.replace(" ", "T")) / 1000 : NaN;
};

const packageCode = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,80}$/.test(value);
const clock = Date.now() / 1000;
const future = value => Number.isFinite(value) && value > clock && value < 4102444800;

async function packageAccounts(kind, codes, signal) {
    if (!codes.length) return [];
    try {
        const reply = await readJSON(await request(kind + "-packages",
            { PageNumber: 1, PageSize: 24, Status: [0, 3], PackageCodes: codes, OnlyValidPeriod: true }, signal));
        const accounts = reply?.data?.Accounts;
        const count = amount(reply?.data?.TotalCount);
        if (reply?.code !== 0 || !Array.isArray(accounts) || accounts.length > 24 ||
            (count == null ? accounts.length === 24 : count > accounts.length)) return [];
        return accounts.filter(row => codes.includes(row?.PackageCode));
    } catch {
        return [];
    }
}

async function packageDates(summary, packages) {
    const totals = new Map();
    for (const item of packages) {
        if (!packageCode(item.PackageCode)) continue;
        const code = item.PackageCode;
        totals.set(code, (totals.get(code) ?? 0) + amount(item.CycleRemainCapacity));
    }
    const planCode = summary.SubscriptionPackageCode;
    const plan = packages.filter(item => packageCode(planCode) && item.PackageCode === planCode);
    const otherCodes = [...totals.keys()].filter(code => code !== planCode && totals.get(code) > 0);
    let reset = plan.length === 1 ? timestamp(plan[0].CycleEndTime) : NaN;
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 3500);
    try {
        const planCodes = !future(reset) && plan.length ? [planCode] : [];
        const paid = summary.IsPaidUser === true;
        const [paidRows, freeRows] = await Promise.all([
            packageAccounts("paid", (paid ? planCodes : []).concat(otherCodes).slice(0, 24), controller.signal),
            packageAccounts("free", (paid ? [] : planCodes).concat(otherCodes).slice(0, 24), controller.signal),
        ]);
        const planRows = (paid ? paidRows : freeRows).filter(row => row.PackageCode === planCode);
        if (!future(reset) && planRows.length) {
            const dates = planRows.map(row => timestamp(row.CycleEndTime) + 1);
            if (future(dates[0]) && dates.every(value => value === dates[0])) reset = dates[0];
        }
        // An expiry needs both an explicit deduction end and a current package remainder.
        // A reset is a renewal, so it is not included in "expiring credits."
        let expires = Infinity, expiring = 0;
        for (const code of otherCodes) {
            const rows = paidRows.concat(freeRows).filter(row => row.PackageCode === code);
            const uniqueRows = rows.filter((row, index) => typeof row.ResourceId !== "string" ||
                rows.findIndex(other => other.ResourceId === row.ResourceId) === index);
            const dated = uniqueRows.map(row => ({
                balance: amount(row.CycleCapacityRemainPrecise), end: timestamp(row.DeductionEndTime),
            }));
            if (dated.some(row => row.balance == null) ||
                Math.abs(dated.reduce((sum, row) => sum + row.balance, 0) - totals.get(code)) > 0.000001) continue;
            for (const row of dated) {
                if (!row.balance || !future(row.end) || row.end > expires) continue;
                if (row.end < expires) { expires = row.end; expiring = 0; }
                expiring += row.balance;
            }
        }
        const sum = key => plan.reduce((total, item) => total + amount(item[key]), 0);
        const cycle = plan.length ? {
            total: sum("CycleTotalCapacity"), remaining: sum("CycleRemainCapacity"),
            used: plan.every(item => amount(item.CycleUsedCapacity) !== null) ? sum("CycleUsedCapacity") : null,
            reset: future(reset) ? reset : null,
        } : null;
        return { cycle, expiration: future(expires) ? { credits: expiring, at: expires } : null };
    } finally { clearTimeout(deadline); }
}

try {
    const response = await request("summary", {});
    if (response.status === 401) return { state: "signIn" };
    const reply = await readJSON(response);
    if (reply?.code === 401 || reply?.code === "401") return { state: "signIn" };
    const entries = reply?.data?.Packages;
    if (reply?.code !== 0 || !Array.isArray(entries) || entries.length > 128) return { state: "unavailable" };
    const packages = entries.filter(item => item?.CapacityUnit === "credits");
    let remaining = 0, total = 0, reserved = 0;
    for (const item of packages) {
        const available = amount(item.CycleRemainCapacity);
        const capacity = amount(item.CycleTotalCapacity);
        const frozen = item.CycleFrozenCapacity == null ? 0 : amount(item.CycleFrozenCapacity);
        if (available === null || capacity === null || frozen === null) return { state: "unavailable" };
        remaining += available;
        total += capacity;
        reserved += frozen;
    }
    // A successful empty list means no active packages. Other units alone
    // give us no information about the credits balance.
    if (entries.length && !packages.length) return { state: "unavailable" };
    const plan = reply.data.SubscriptionPackageName;
    return { state: "ready", remaining, total, reserved,
        plan: typeof plan === "string" ? plan.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, "").trim().slice(0, 80) : "",
        ...(packages.length ? await packageDates(reply.data, packages) : {}) };
} catch {
    return { state: "unavailable" };
}
