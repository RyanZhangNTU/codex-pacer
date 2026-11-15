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

// WorkBuddy's own package families, as its usage page groups them: plan base
// and plan bonus refresh every cycle; rewards and top-ups never refresh and
// lapse at their own dates.
const codeNumber = code => { const match = /^TCACA_code_(\d{3})_/.exec(code); return match ? Number(match[1]) : null; };
const family = number => [1, 2, 3, 5, 6, 8, 23, 26, 27, 35, 39, 40, 43].includes(number) ? "planBase"
    : [28, 37].includes(number) ? "planBonus" : [7, 29, 30].includes(number) ? "reward"
    : [9, 36, 38].includes(number) ? "topUp" : null;
const kindOf = (code, subscription) => family(codeNumber(code)) ?? (code === subscription ? "planBase" : "reward");
const refreshes = kind => kind === "planBase" || kind === "planBonus";
// Only the highest plan counts, as on WorkBuddy's own account page.
const tier = { 43: 5, 27: 4, 26: 3, 2: 2, 3: 2, 5: 2, 23: 1 };
const kinds = ["planBase", "planBonus", "reward", "topUp"];

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

async function readGroups(summary, packages) {
    const subscription = summary.SubscriptionPackageCode;
    const codes = new Map();
    for (const item of packages) {
        if (!packageCode(item.PackageCode)) continue;
        const entry = codes.get(item.PackageCode) ?? { kind: kindOf(item.PackageCode, subscription), remaining: 0, total: 0, used: 0, usedKnown: true, refresh: NaN };
        entry.remaining += amount(item.CycleRemainCapacity);
        entry.total += amount(item.CycleTotalCapacity);
        const used = amount(item.CycleUsedCapacity);
        if (used === null) entry.usedKnown = false; else entry.used += used;
        // The cycle ends at its last second; the refresh is the moment after.
        const end = timestamp(item.CycleEndTime) + 1;
        if (future(end) && !(end > entry.refresh)) entry.refresh = end;
        codes.set(item.PackageCode, entry);
    }
    const undated = [...codes].filter(([, entry]) => refreshes(entry.kind) && !future(entry.refresh)).map(([code]) => code);
    const lapsing = [...codes].filter(([, entry]) => !refreshes(entry.kind) && entry.remaining > 0).map(([code]) => code);
    const batches = new Map();
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 3500);
    try {
        const paid = summary.IsPaidUser === true;
        const [paidRows, freeRows] = await Promise.all([
            packageAccounts("paid", (paid ? undated : []).concat(lapsing).slice(0, 24), controller.signal),
            packageAccounts("free", (paid ? [] : undated).concat(lapsing).slice(0, 24), controller.signal),
        ]);
        const rows = paidRows.concat(freeRows);
        for (const code of undated) {
            const dates = rows.filter(row => row.PackageCode === code).map(row => timestamp(row.CycleEndTime) + 1);
            if (dates.length && future(dates[0]) && dates.every(value => value === dates[0])) codes.get(code).refresh = dates[0];
        }
        // A batch's date counts only when the dated rows add up to the package's balance.
        for (const code of lapsing) {
            const own = rows.filter(row => row.PackageCode === code);
            const unique = own.filter((row, index) => typeof row.ResourceId !== "string" ||
                own.findIndex(other => other.ResourceId === row.ResourceId) === index);
            const dated = unique.map(row => ({ credits: amount(row.CycleCapacityRemainPrecise), at: timestamp(row.DeductionEndTime) }));
            if (dated.some(row => row.credits == null) ||
                Math.abs(dated.reduce((sum, row) => sum + row.credits, 0) - codes.get(code).remaining) > 0.000001) continue;
            batches.set(code, dated.filter(row => row.credits > 0 && future(row.at)));
        }
    } finally { clearTimeout(deadline); }

    const groups = [];
    for (const kind of kinds) {
        const members = [...codes].filter(([, entry]) => entry.kind === kind);
        if (!members.length) continue;
        const remaining = members.reduce((sum, [, entry]) => sum + entry.remaining, 0);
        if (refreshes(kind)) {
            const dates = members.map(([, entry]) => entry.refresh).filter(future);
            groups.push({ kind, remaining, total: members.reduce((sum, [, entry]) => sum + entry.total, 0),
                refresh: dates.length ? Math.min(...dates) : null });
        } else {
            const expiries = members.flatMap(([code]) => batches.get(code) ?? []).sort((a, b) => a.at - b.at).slice(0, 24);
            groups.push({ kind, remaining, expiries });
        }
    }
    // Earlier hosts read the plan cycle and the earliest lapse directly.
    const planEntries = [...codes].filter(([code]) => code === subscription).map(([, entry]) => entry);
    const cycle = planEntries.length ? {
        total: planEntries.reduce((sum, entry) => sum + entry.total, 0),
        remaining: planEntries.reduce((sum, entry) => sum + entry.remaining, 0),
        used: planEntries.every(entry => entry.usedKnown) ? planEntries.reduce((sum, entry) => sum + entry.used, 0) : null,
        reset: planEntries.map(entry => entry.refresh).find(future) ?? null,
    } : null;
    const lapses = groups.flatMap(group => group.expiries ?? []).sort((a, b) => a.at - b.at);
    const expiration = lapses.length ? { credits: lapses.filter(row => row.at === lapses[0].at).reduce((sum, row) => sum + row.credits, 0), at: lapses[0].at } : null;
    return { groups, cycle, expiration };
}

try {
    const response = await request("summary", {});
    if (response.status === 401) return { state: "signIn" };
    const reply = await readJSON(response);
    if (reply?.code === 401 || reply?.code === "401") return { state: "signIn" };
    const entries = reply?.data?.Packages;
    if (reply?.code !== 0 || !Array.isArray(entries) || entries.length > 128) return { state: "unavailable" };
    let packages = entries.filter(item => item?.CapacityUnit === "credits");
    for (const item of packages) {
        const frozen = item.CycleFrozenCapacity == null ? 0 : amount(item.CycleFrozenCapacity);
        if (amount(item.CycleRemainCapacity) === null || amount(item.CycleTotalCapacity) === null || frozen === null) return { state: "unavailable" };
    }
    // A successful empty list means no active packages. Other units alone
    // give us no information about the credits balance.
    if (entries.length && !packages.length) return { state: "unavailable" };
    const subscription = reply.data.SubscriptionPackageCode;
    const plans = packages.filter(item => packageCode(item.PackageCode) && kindOf(item.PackageCode, subscription) === "planBase");
    if (new Set(plans.map(item => item.PackageCode)).size > 1) {
        const score = item => [tier[codeNumber(item.PackageCode)] ?? 0, amount(item.CycleRemainCapacity) > 0 ? 1 : 0, amount(item.CycleTotalCapacity)];
        const better = (a, b) => { const x = score(a), y = score(b); return x[0] - y[0] || x[1] - y[1] || x[2] - y[2]; };
        const best = plans.reduce((kept, item) => better(item, kept) > 0 ? item : kept);
        packages = packages.filter(item => !plans.includes(item) || item.PackageCode === best.PackageCode);
    }
    let remaining = 0, total = 0, reserved = 0;
    for (const item of packages) {
        remaining += amount(item.CycleRemainCapacity);
        total += amount(item.CycleTotalCapacity);
        reserved += item.CycleFrozenCapacity == null ? 0 : amount(item.CycleFrozenCapacity);
    }
    const plan = reply.data.SubscriptionPackageName;
    return { state: "ready", remaining, total, reserved,
        plan: typeof plan === "string" ? plan.replace(/[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/g, "").trim().slice(0, 80) : "",
        ...(packages.length ? await readGroups(reply.data, packages) : {}) };
} catch {
    return { state: "unavailable" };
}
