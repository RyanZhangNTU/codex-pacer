using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace CodexPacer.Windows;

/// The desktop holds native controls and its preference transaction. Swift Core owns group edits and order.
internal sealed class NativePinnedGroups(string directory)
{
    private static readonly Lazy<NativePinnedGroups> Default = new(() => new(Path.Combine(AppContext.BaseDirectory, "Engine")));
    internal static NativePinnedGroups Shared => Default.Value;
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int Project(int action, [In] byte[] input, int size, [Out] byte[] output, int capacity);
    private readonly Lazy<Project> project = new(() => NativeMotion.SharedExport<Project>(directory, "pacer_pinned_groups_project"));
    private sealed record Section(string? group, string[] members);
    private ConversationGroup[]? previousGroups;
    private (string Id, bool Running)[] previousRows = [];
    private Section[] sections = [];

    internal (ConversationGroup? Group, EngineTaskRow[] Rows)[] Sections(ConversationGroup[] groups, IEnumerable<EngineTaskRow> rows)
    {
        var byId = rows.ToDictionary(row => row.Id);
        var states = byId.Values.Select(row => (row.Id, Running: row.Phase == "running")).ToArray();
        if (!ReferenceEquals(groups, previousGroups) || !states.SequenceEqual(previousRows))
        {
            sections = Read<Section[]>(0, new { groups, ids = states.Select(r => r.Id), running = states.Where(r => r.Running).Select(r => r.Id) });
            previousGroups = groups;
            previousRows = states;
        }
        var saved = groups.ToDictionary(g => g.Id);
        return sections.Select(s => (s.group == null ? null : saved[s.group], s.members.Select(id => byId[id]).ToArray())).ToArray();
    }
    internal ConversationGroup[] Move(ConversationGroup[] groups, string[] members, string? destination, string? name = null) =>
        Read<ConversationGroup[]>(1, new { groups, members, destination, name });
    internal ConversationGroup[] DropGroup(ConversationGroup[] groups, string source, string? destination, bool after, bool merge) =>
        Read<ConversationGroup[]>(2, new { groups, source, destination, after, merge });

    private T Read<T>(int action, object request) where T : class
    {
        var input = JsonSerializer.SerializeToUtf8Bytes(request);
        var capacity = Math.Clamp(input.Length + 1024, 1024, 1024 * 1024);
        while (true)
        {
            var buffer = ArrayPool<byte>.Shared.Rent(capacity);
            try
            {
                int length = project.Value(action, input, input.Length, buffer, capacity);
                if (length > 0 && length <= capacity)
                    return JsonSerializer.Deserialize<T>(buffer.AsSpan(0, length)) ?? throw new InvalidDataException();
                if (length >= -capacity || length < -1024 * 1024) throw new InvalidDataException("Invalid pinned group projection.");
                capacity = -length;
            }
            finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
        }
    }
}
