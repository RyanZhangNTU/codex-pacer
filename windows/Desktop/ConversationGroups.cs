using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace CodexPacer.Windows;

internal sealed record ConversationGroup(string Id, string Name, string[] Members, bool Collapsed = false);
internal sealed record ConversationGroups(Dictionary<string, ConversationGroup[]> Profiles)
{
    private static bool Valid(ConversationGroup[] groups) =>
        groups != null && groups.Length <= 256 && groups.All(g => g != null && !string.IsNullOrWhiteSpace(g.Id)
            && g.Name != null && g.Name.Length <= 64 && g.Members != null && g.Members.Length <= 256
            && g.Members.All(m => !string.IsNullOrWhiteSpace(m)))
        && groups.Select(g => g.Id).Distinct().Count() == groups.Length
        && groups.SelectMany(g => g.Members).Distinct().Count() == groups.Sum(g => g.Members.Length);

    internal static ConversationGroups Read(string? json)
    {
        try
        {
            if (json == null || json.Length > 262144) return new([]);
            var value = JsonSerializer.Deserialize<ConversationGroups>(json);
            if (value?.Profiles == null || value.Profiles.Count > 32 || !value.Profiles.Values.All(Valid)) return new([]);
            return value;
        }
        catch (JsonException) { return new([]); }
    }
    internal ConversationGroup[] For(string profile) => Profiles.GetValueOrDefault(profile, []);
    internal string Update(string profile, ConversationGroup[] groups)
    {
        var copy = new Dictionary<string, ConversationGroup[]>(Profiles);
        if (!Valid(groups)) throw new InvalidOperationException();
        if (groups.Length == 0) copy.Remove(profile);
        else copy[profile] = groups;
        if (copy.Count > 32) throw new InvalidOperationException();
        return JsonSerializer.Serialize(new ConversationGroups(copy));
    }
}
