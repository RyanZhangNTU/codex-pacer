using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Xml.Linq;

namespace CodexPacer.Windows;

internal enum NotificationAvailability { Available, Denied, Unsupported, Failed }
internal sealed record NotificationContent(string Id, string Title, string Body, IReadOnlyList<EngineNoticeAction> Actions);
internal interface ISystemNotifications : IDisposable
{
    event Action<string>? Activated;
    Task<NotificationAvailability> EnableAsync();
    Task DisableAsync();
    Task ClearAsync();
    bool Deliver(NotificationContent content);
}

/// XML contains only text and a fixed action vocabulary. Notice identifiers
/// are hashed for the OS tag; task/source identities never become launch args.
internal static class NotificationPayload
{
    internal static string Tag(string id) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))).Substring(0, 16);
    internal static bool IsAction(string value) => value is "showIsland" or "snoozeSpike" or "topUp" or "openHarness";
    internal static string Argument(string action) => "pacer=1&action=" + action;
    internal static string? ParseAction(string? value)
    {
        if (value == null || value.Length > 128) return null;
        foreach (string action in new[] { "showIsland", "snoozeSpike", "topUp", "openHarness" }) if (value == Argument(action)) return action;
        return null;
    }
    internal static string Xml(NotificationContent content)
    {
        var root = new XElement("toast", new XAttribute("launch", Argument("showIsland")),
            new XElement("visual", new XElement("binding", new XAttribute("template", "ToastGeneric"),
                new XElement("text", content.Title), new XElement("text", content.Body))), new XElement("audio", new XAttribute("silent", "true")));
        var actions = new XElement("actions");
        foreach (var action in content.Actions)
            if (IsAction(action.Kind) && action.Kind != "showIsland") actions.Add(new XElement("action", new XAttribute("content", action.Title),
                new XAttribute("arguments", Argument(action.Kind)), new XAttribute("activationType", "foreground")));
        if (actions.HasElements) root.Add(actions);
        return root.ToString(SaveOptions.DisableFormatting);
    }
}
