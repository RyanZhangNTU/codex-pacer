namespace CodexPacer.Windows;

internal readonly record struct ScreenRectangle(int Left, int Top, int Right, int Bottom)
{
    internal bool Valid => Right > Left && Bottom > Top;
    internal bool Contains(ScreenRectangle other) => Valid && other.Valid && Left <= other.Left && Top <= other.Top && Right >= other.Right && Bottom >= other.Bottom;
}

// A transparent overlay may leave the island visible. Only a complete,
// opaque cover above this HWND suspends cosmetic animation.
internal static class FullscreenOcclusionPolicy
{
    internal static bool Covers(ScreenRectangle window, ScreenRectangle monitor, ScreenRectangle island,
        bool above, bool visible, bool cloaked, bool layered, bool noRedirection, bool regionContainsIsland)
        => above && visible && !cloaked && !layered && !noRedirection && regionContainsIsland
            && window.Contains(monitor) && window.Contains(island);
}
