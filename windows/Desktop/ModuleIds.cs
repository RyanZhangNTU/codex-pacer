using System.Collections.Generic;
using System.Linq;

namespace CodexPacer.Windows;

/// Module IDs as the engine's registry spells them: lowercase words joined by
/// hyphens. Preferences and the engine client share these rules.
internal static class ModuleIds
{
    /// The modules every engine has supported, including those that predate the registry.
    internal static IReadOnlyList<string> Legacy { get; } = ["codex", "claude", "deepseek"];
    internal static bool IsLegacy(string id) => Legacy.Contains(id);
    internal static bool Valid(string id) => id.Length is > 0 and <= 48 && id[0] is >= 'a' and <= 'z'
        && id.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-');
}
