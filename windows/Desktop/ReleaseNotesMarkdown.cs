using System;
using System.Collections.Generic;
using System.Text;

namespace CodexPacer.Windows;

internal enum NoteBlockKind { Heading, Paragraph, Bullet, Numbered }
internal enum NoteSpanKind { Text, Strong, Code, Link }
internal sealed record NoteSpan(NoteSpanKind Kind, string Text, Uri? Link = null);
internal sealed record NoteBlock(NoteBlockKind Kind, IReadOnlyList<NoteSpan> Spans, int Level = 0, int Number = 0);

/// The release notes' Markdown subset: #–### headings, paragraphs, - * and 1.
/// lists, **strong**, `code`, [text](url) and backslash escapes. Anything else,
/// HTML included, is literal text. Links are kept only for GitHub over HTTPS.
internal static class ReleaseNotesMarkdown
{
    internal const int MaximumBlocks = 500;
    internal static IReadOnlyList<NoteBlock> Parse(string? markdown)
    {
        var blocks = new List<NoteBlock>();
        var paragraph = new StringBuilder();
        void Flush()
        {
            if (paragraph.Length == 0) return;
            Add(new(NoteBlockKind.Paragraph, Spans(paragraph.ToString()))); paragraph.Clear();
        }
        void Add(NoteBlock block) { if (blocks.Count < MaximumBlocks) blocks.Add(block); }
        foreach (string raw in (markdown ?? "").Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            string line = raw.TrimEnd();
            string trimmed = line.TrimStart();
            if (trimmed.Length == 0) { Flush(); continue; }
            int hashes = 0;
            while (hashes < trimmed.Length && trimmed[hashes] == '#') hashes++;
            if (hashes is >= 1 and <= 3 && hashes < trimmed.Length && trimmed[hashes] == ' ')
            { Flush(); Add(new(NoteBlockKind.Heading, Spans(trimmed[(hashes + 1)..].Trim()), hashes)); continue; }
            if (trimmed.Length > 2 && (trimmed[0] is '-' or '*') && trimmed[1] == ' ')
            { Flush(); Add(new(NoteBlockKind.Bullet, Spans(trimmed[2..].Trim()))); continue; }
            int digits = 0;
            while (digits < trimmed.Length && digits < 4 && char.IsAsciiDigit(trimmed[digits])) digits++;
            if (digits > 0 && digits + 1 < trimmed.Length && trimmed[digits] == '.' && trimmed[digits + 1] == ' ')
            { Flush(); Add(new(NoteBlockKind.Numbered, Spans(trimmed[(digits + 2)..].Trim()), Number: int.Parse(trimmed[..digits], System.Globalization.CultureInfo.InvariantCulture))); continue; }
            if (paragraph.Length > 0) paragraph.Append(' ');
            paragraph.Append(trimmed);
        }
        Flush();
        return blocks;
    }
    internal static IReadOnlyList<NoteSpan> Spans(string text)
    {
        var spans = new List<NoteSpan>();
        var plain = new StringBuilder();
        void Plain() { if (plain.Length > 0) { spans.Add(new(NoteSpanKind.Text, plain.ToString())); plain.Clear(); } }
        for (int i = 0; i < text.Length; i++)
        {
            char c = text[i];
            if (c == '\\' && i + 1 < text.Length && "\\`*_[]()#-!.".Contains(text[i + 1])) { plain.Append(text[++i]); continue; }
            if (c == '*' && i + 1 < text.Length && text[i + 1] == '*')
            {
                int end = text.IndexOf("**", i + 2, StringComparison.Ordinal);
                if (end > i + 2) { Plain(); spans.Add(new(NoteSpanKind.Strong, Unescape(text[(i + 2)..end]))); i = end + 1; continue; }
            }
            if (c == '`')
            {
                int end = text.IndexOf('`', i + 1);
                if (end > i + 1) { Plain(); spans.Add(new(NoteSpanKind.Code, text[(i + 1)..end])); i = end; continue; }
            }
            if (c == '[')
            {
                int close = text.IndexOf("](", i + 1, StringComparison.Ordinal), end = close < 0 ? -1 : text.IndexOf(')', close + 2);
                if (close > i + 1 && end > close + 2)
                {
                    Plain();
                    string label = Unescape(text[(i + 1)..close]);
                    spans.Add(Allowed(text[(close + 2)..end]) is { } link ? new(NoteSpanKind.Link, label, link) : new(NoteSpanKind.Text, label));
                    i = end; continue;
                }
            }
            plain.Append(c);
        }
        Plain();
        return spans;
    }
    private static string Unescape(string text)
    {
        var result = new StringBuilder(text.Length);
        for (int i = 0; i < text.Length; i++) result.Append(text[i] == '\\' && i + 1 < text.Length ? text[++i] : text[i]);
        return result.ToString();
    }
    /// The guide's link policy: HTTPS on github.com, default port, no user info.
    internal static Uri? Allowed(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
        && uri.IsDefaultPort && uri.UserInfo.Length == 0 && string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase) ? uri : null;
}
