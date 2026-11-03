using System;
using System.IO;
using Microsoft.Win32;

namespace CodexPacer.Windows;

internal sealed record NotificationRegistration(string MappingKey, string AppKey, string ClassKey, string AppId, string Activator, string Command)
{
    internal const string Root = @"Software\Classes\AppUserModelId\";
    internal static NotificationRegistration? Find(string executable, IUserRegistrationStore store)
    {
        executable = Path.GetFullPath(executable);
        // This is the pinned Windows App SDK's ConvertPathToKey mapping.
        // Read before constructing Default: its constructor creates a mapping.
        string mapping = Root + executable.Replace('\\', '.');
        var value = store.Read(mapping, "NotificationGUID");
        if (value == null) return null;
        if (value is not { Kind: RegistryValueKind.String, Value: string app } ||
            !Guid.TryParseExact(app, "B", out _)) throw new InvalidDataException("The notification mapping is invalid.");
        string appKey = Root + app;
        var activator = store.Read(appKey, "CustomActivator");
        if (activator is not { Kind: RegistryValueKind.String, Value: string clsid } || !Guid.TryParseExact(clsid, "B", out _))
            throw new InvalidDataException("The notification activation record is incomplete.");
        string classKey = @"Software\Classes\CLSID\" + clsid;
        string command = "\"" + executable + "\" ----AppNotificationActivated:";
        if (store.Read(classKey + @"\LocalServer32", "") is not { Kind: RegistryValueKind.String, Value: string actual } ||
            !string.Equals(actual.Trim(), command, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The notification activation belongs to a different executable.");
        return new(mapping, appKey, classKey, app, clsid, command);
    }
    internal void RemoveMapping(IUserRegistrationStore store)
    {
        if (store.Read(MappingKey, "NotificationGUID") is { Kind: RegistryValueKind.String, Value: string current } && current == AppId)
        { store.Delete(MappingKey, "NotificationGUID"); store.DeleteEmptyKey(MappingKey); }
    }
}
