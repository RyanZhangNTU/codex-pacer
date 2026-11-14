using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace CodexPacer.Windows;

internal sealed record ConversationGroup(string Id, string Name, string[] Members, bool Collapsed = false);
internal sealed record ConversationGroups(Dictionary<string, ConversationGroup[]> Profiles)
{
    internal static ConversationGroups Read(string? json)
    {
        try
        {
            if (json == null || json.Length > 262144) return new([]);
            var value = JsonSerializer.Deserialize<ConversationGroups>(json);
            if (value?.Profiles == null || value.Profiles.Count > 32 || value.Profiles.Values.Any(groups => groups == null || groups.Length > 256 ||
                groups.Any(g => g == null || string.IsNullOrWhiteSpace(g.Id) || g.Name == null || g.Name.Length > 64 || g.Members == null || g.Members.Length > 256))) return new([]);
            return value;
        }
        catch (JsonException) { return new([]); }
    }
    internal ConversationGroup[] For(string profile) => Profiles.GetValueOrDefault(profile, []);
    internal string Update(string profile, ConversationGroup[] groups)
    {
        var copy = new Dictionary<string, ConversationGroup[]>(Profiles) { [profile] = groups };
        return JsonSerializer.Serialize(new ConversationGroups(copy));
    }
    internal static ConversationGroup[] Move(ConversationGroup[] groups, string[] members, string? destination, string? name = null)
    {
        var moved = members.ToHashSet(StringComparer.Ordinal);
        var result = groups.Select(g => g with { Members = g.Members.Where(m => !moved.Contains(m)).ToArray() }).ToList();
        if (destination != null)
        {
            var index = result.FindIndex(g => g.Id == destination);
            if (index < 0) result.Add(new(destination, name ?? "", members.Distinct().ToArray()));
            else result[index] = result[index] with { Members = result[index].Members.Concat(members).Distinct().ToArray() };
        }
        return result.Where(g => g.Members.Length > 0).ToArray();
    }
    // Group drags reorder by default. Combining membership always requires an explicit merge.
    internal static ConversationGroup[] DropGroup(ConversationGroup[] groups, string source, string? destination, bool after, bool merge)
    {
        var dragged = groups.FirstOrDefault(g => g.Id == source);
        if (dragged == null || source == destination || destination != null && !groups.Any(g => g.Id == destination)) return groups;
        if (merge) return destination == null ? groups : Move(groups, dragged.Members, destination);
        var result = groups.Where(g => g.Id != source).ToList();
        var index = destination == null ? result.Count : result.FindIndex(g => g.Id == destination) + (after ? 1 : 0);
        result.Insert(index, dragged);
        return result.ToArray();
    }
}
