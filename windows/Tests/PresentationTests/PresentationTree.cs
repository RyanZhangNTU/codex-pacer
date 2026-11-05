global using static PresentationTree;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

/// Visual-tree walks shared by the presentation checks, in pre-order.
internal static class PresentationTree
{
    /// Every visual descendant of the root, excluding the root itself.
    internal static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }

    /// The root followed by every visual descendant.
    internal static IEnumerable<DependencyObject> SelfAndDescendants(DependencyObject root)
    {
        yield return root;
        foreach (var child in Descendants(root)) yield return child;
    }
}
