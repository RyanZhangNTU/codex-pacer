using CodexPacer.Windows;

internal static class ConversationOrderChecks
{
    internal static void Run()
    {
        var groups = new[] { new ConversationGroup("a", "First", ["a1", "a2"]), new ConversationGroup("b", "Second", ["b1", "b2"], true) };
        var saved = ConversationGroups.Read(null).Update("profile", groups);
        EngineTaskRow Row(string id, string phase = "idle") => new(id, "codex", id, phase, null, null, null, phase, "moon", null, "", null, null, false, null, null, 0, false, false, false, null, false);
        var rows = new[] { Row("a1"), Row("a2"), Row("b1"), Row("b2", "running"), Row("z2"), Row("z1") };
        var shown = ConversationGroups.Sections(groups, rows);
        Check(shown.Select(s => s.Group?.Id).SequenceEqual(new string?[] { "b", "a", null }) && shown[0].Group!.Collapsed, "An active group rises without changing its collapsed state");
        Check(shown[0].Rows.Select(r => r.Id).SequenceEqual(new[] { "b2", "b1" }), "Running members precede idle members");
        Check(shown[2].Rows.Select(r => r.Id).SequenceEqual(new[] { "z1", "z2" }), "Ungrouped idle rows keep their stable order");
        rows[1] = Row("a2", "running");
        shown = ConversationGroups.Sections(groups, rows);
        Check(shown[0].Group!.Id == "a" && shown[1].Group!.Id == "b", "Equally active groups retain manual order");
        rows[3] = Row("b2", "completed"); rows[1] = Row("a2", "waitingForInput"); rows[4] = Row("z2", "running");
        shown = ConversationGroups.Sections(groups, rows);
        Check(shown[0].Group == null && shown[0].Rows[0].Id == "z2", "Ungrouped activity rises too; waiting or completed chats are not running");
        rows = rows.Select(r => r with { Phase = "idle" }).ToArray();
        shown = ConversationGroups.Sections(groups, rows);
        Check(shown.Select(s => s.Group?.Id).SequenceEqual(new string?[] { "a", "b", null }) && shown[0].Rows.Select(r => r.Id).SequenceEqual(new[] { "a1", "a2" }), "Ending activity restores manual group and member order");
        Check(ConversationGroups.Read(null).Update("profile", groups) == saved, "Activity projection never changes persisted groups");
        var limit = new ConversationGroups(new());
        for (int i = 0; i < 32; i++) limit = ConversationGroups.Read(limit.Update(i.ToString(), groups));
        bool rejected = false;
        try { limit.Update("overflow", groups); } catch (InvalidOperationException) { rejected = true; }
        Check(rejected && limit.For("0").Length == 2, "An additional profile cannot invalidate existing groups");
        var absent = ConversationGroups.Sections(groups, [Row("a1")]);
        Check(absent.Length == 2 && absent[0].Group!.Id == "a" && absent[1].Rows.Length == 0, "Missing pins do not create empty saved-group sections; Ungrouped remains a drop target");
    }
    private static void Check(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
}
