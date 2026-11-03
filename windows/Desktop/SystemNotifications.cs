using System;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Xml.Linq;

namespace CodexPacer.Windows;

internal enum NotificationAvailability { Available, Denied, Unsupported, Failed }
internal sealed record NotificationContent(string Id, string Title, string Body, IReadOnlyList<EngineNoticeAction> Actions, EngineNoticeAction? DefaultAction = null);
internal interface ISystemNotifications : IDisposable
{
    event Action<string>? Activated;
    Task<NotificationAvailability> EnableAsync();
    Task DisableAsync();
    Task ClearAsync();
    bool Deliver(NotificationContent content);
    NotificationAvailability? CurrentAvailability => null;
}

/// XML contains only text and a fixed action vocabulary. Notice identifiers
/// are hashed for the OS tag; task/source identities never become launch args.
internal static class NotificationPayload
{
    internal static string Tag(string id) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))).Substring(0, 16);
    internal static bool IsAction(string value) => value is "showIsland" or "openTask" or "snoozeSpike" or "topUp" or "openHarness";
    internal static bool IsReference(string? value) => value is { Length: 32 } && System.Linq.Enumerable.All(value, c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    internal static string Argument(string action, string reference) => IsAction(action) && IsReference(reference)
        ? "pacer=2&action=" + action + "&ref=" + reference : "pacer=2";
    internal static string? ParseAction(string? value)
    {
        if (value == null || value.Length > 128) return null;
        foreach (string action in new[] { "showIsland", "openTask", "snoozeSpike", "topUp", "openHarness" })
        {
            string prefix = "pacer=2&action=" + action + "&ref=";
            if (value.StartsWith(prefix, StringComparison.Ordinal) && IsReference(value[prefix.Length..])) return action;
        }
        return null;
    }
    internal static string? ParseReference(string? value) => value == null || ParseAction(value) == null ? null : value[(value.LastIndexOf('=') + 1)..];
    internal static string Xml(NotificationContent content, bool longDuration = false)
    {
        var root = new XElement("toast", new XAttribute("launch", content.DefaultAction is { } main ? Argument(main.Kind, main.Reference ?? "") : "pacer=2"),
            new XElement("visual", new XElement("binding", new XAttribute("template", "ToastGeneric"),
                new XElement("text", content.Title), new XElement("text", content.Body))), new XElement("audio", new XAttribute("silent", "true")));
        var actions = new XElement("actions");
        if (longDuration) root.SetAttributeValue("duration", "long");
        foreach (var action in content.Actions)
            if (IsAction(action.Kind) && action.Kind != "showIsland" && IsReference(action.Reference)) actions.Add(new XElement("action", new XAttribute("content", action.Title),
                new XAttribute("arguments", Argument(action.Kind, action.Reference!)), new XAttribute("activationType", "foreground")));
        if (actions.HasElements) root.Add(actions);
        return root.ToString(SaveOptions.DisableFormatting);
    }
}
