using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using CodexPacer.Windows;

internal static class ConversationApplicationChecks
{
    internal static async Task Run()
    {
        string context = Guid.NewGuid().ToString("D"), session = "11111111-1111-4111-8111-111111111111";
        var launched = new List<(string Family, Uri Uri)>(); var pages = new List<Uri>(); var hosts = new List<(uint, ulong)>();
        bool succeeds = true, throws = false, installed = true;
        var apps = new WindowsDesktopApplications(_ => installed, _ => false,
            activateProtocol: (family, uri) => { launched.Add((family, uri)); if (throws) throw new COMException("Synthetic activation failure"); return Task.FromResult(succeeds); },
            activateWeb: uri => { pages.Add(uri); return Task.FromResult(true); },
            activateHost: (pid, started) => { hosts.Add((pid, started)); return true; });
        EngineNavigationPlan Local(string uri, string? web = null, string provider = "claude") => new(context, provider, "application", uri, web, null, null);
        string local = "claude://code/continue?session=local_" + session;
        Check(await apps.OpenConversationAsync(Local(local)) && launched[0].Family == "Claude_pzs8sxrjxfjjc", "Claude links must target the registered Claude package");
        Check(await apps.OpenConversationAsync(Local("codex://threads/" + session, provider: "codex")) && launched[1].Family == "OpenAI.Codex_2p2nqsd0c76g0", "Codex links must target the registered Codex package");
        succeeds = false;
        Check(!await apps.OpenConversationAsync(Local(local)) && pages.Count == 0, "A failed local open cannot fall back to an unrelated web chat");
        string cloud = "claude://code/project/chan_fixture123?thread=session_thread123", web = "https://claude.ai/code/project/chan_fixture123?thread=session_thread123";
        Check(await apps.OpenConversationAsync(Local(cloud, web)) && pages[^1].AbsoluteUri == web, "Cloud failure must fall back to the same project and thread");
        throws = true;
        Check(await apps.OpenConversationAsync(Local(cloud, web)), "A provider activation exception must still allow the matching Cloud web fallback");
        throws = false; installed = false;
        int protocols = launched.Count;
        Check(await apps.OpenConversationAsync(Local(cloud, web)) && launched.Count == protocols, "Missing Desktop may open the matching Cloud page without launching a generic handler");
        Check(!await apps.OpenConversationAsync(Local(local)), "Missing Desktop cannot manufacture a successful local conversation open");
        installed = true; int before = launched.Count, browserBefore = pages.Count;
        foreach (string invalid in new[] {
            "https://claude.ai/", "claude://elsewhere/continue?session=local_" + session,
            local + "&other=value", local + "#fragment", "claude://code:321/continue?session=local_" + session,
            "claude://code@elsewhere/continue?session=local_" + session, "claude://code/continue?session=not-a-desktop-session",
            "claude://code/project/chan_fixture123?thread=cmsg_pending_fixture", "claude://code/project/not-a-channel",
            "claude://code/project/chan_fixture123?thread=session_thread123&thread=session_other123" })
            Check(!await apps.OpenConversationAsync(Local(invalid)), "Unsafe Claude destination reached activation: " + invalid);
        Check(!await apps.OpenConversationAsync(Local(cloud, "https://claude.ai/code/project/chan_another123")), "Cloud fallback must match its exact destination");
        Check(!await apps.OpenConversationAsync(Local("codex://threads//" + session, provider: "codex")), "Codex must reject extra path segments");
        Check(!await apps.OpenConversationAsync(Local("codex://threads/" + session + "?config=anything", provider: "codex")), "Codex navigation cannot pass configuration or prompts");
        Check(launched.Count == before && pages.Count == browserBefore, "Rejected plans must not reach any OS launch callback");
        Check(await apps.OpenConversationAsync(new(context, "claude", "host", null, null, 12, 34)) && hosts.Count == 1, "An owner plan may activate its existing process instance");
        Check(!await apps.OpenConversationAsync(new(context, "claude", "host", local, null, 12, 34)), "An owner plan cannot contain an executable or URI");
        Check(!await apps.OpenConversationAsync(new(context, "claude", "host", null, null, 12, 0)), "An owner PID without its creation identity is insufficient");
        Check(!await apps.OpenConversationAsync(new(context, "claude", "demo", null, null, null, null)), "The OS launcher cannot execute a demo plan");
        var capabilities = new List<string>();
        Task<bool> ActivatePrepared(string value) { capabilities.Add(value); return Task.FromResult(false); }
        Check(!await apps.OpenConversationAsync(new(context, "codex", "host", null, null, 12, 34), ActivatePrepared) && capabilities.Count == 1 && capabilities[0] == context && hosts.Count == 1,
            "A failed prepared-host activation stays failed and cannot fall through to a live PID or provider URI");
        Check(!await apps.OpenConversationAsync(new(context, "codex", "host", local, null, 12, 34), ActivatePrepared) && capabilities.Count == 1,
            "A prepared host must reject mixed executable or URI payloads before asking the engine");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
