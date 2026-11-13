using System;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CodexPacer.Windows;

internal static class ProviderIcon
{
    private static readonly Dictionary<(string Provider, bool Outline), ImageSource> Sources = new();

    internal static ImageSource? Source(string provider, bool outline = false)
    {
        var key = (provider, outline);
        if (Sources.TryGetValue(key, out var source)) return source;
        if (provider is not ("codex" or "claude" or "deepseek" or "workbuddy")) return null;
        string name = "provider-" + provider + (outline ? "-outline" : "");
        var bitmap = new BitmapImage(new Uri("pack://application:,,,/CodexPacer;component/Assets/Providers/" + name + ".png"));
        bitmap.Freeze();
        Sources.Add(key, bitmap);
        return bitmap;
    }

    internal static FrameworkElement Create(string provider, double size, string? fallback = null) =>
        Source(provider) is { } source
            ? new Image { Source = source, Width = size, Height = size, Stretch = Stretch.Uniform, IsHitTestVisible = false,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
            : new IconGlyph { Symbol = fallback ?? GuideArt.ProviderSymbol(provider), Width = size, Height = size, Ink = PacerPalette.Provider(provider) };

    internal static FrameworkElement CreateLaunch(string provider, double size, Control? owner = null, string? fallback = null)
    {
        FrameworkElement icon;
        DependencyProperty ink;
        if (Source(provider, outline: true) is { } source)
        {
            var mask = new ImageBrush(source) { Stretch = Stretch.Uniform };
            mask.Freeze();
            icon = new Border { OpacityMask = mask };
            ink = Border.BackgroundProperty;
        }
        else
        {
            icon = new IconGlyph { Symbol = fallback ?? GuideArt.ProviderSymbol(provider) };
            ink = IconGlyph.InkProperty;
        }
        icon.Width = icon.Height = size;
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.IsHitTestVisible = false;
        if (owner == null) icon.SetResourceReference(ink, "Island.Secondary");
        else icon.SetBinding(ink, new Binding(nameof(Control.Foreground)) { Source = owner });
        return icon;
    }

    internal static Border Tile(string provider, double size, string? fallback = null) =>
        new() { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center, Child = Create(provider, size, fallback) };

    internal static FrameworkElement Caption(string provider)
    {
        var icon = Create(provider, 13);
        icon.Margin = new Thickness(0, 0, 4, 0);
        return icon;
    }
}
