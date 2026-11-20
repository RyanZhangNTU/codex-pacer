global using static PresentationTree;
using System.Collections.Generic;
using System.Windows;
using System.Windows.Media;

/// Tree walks shared by the presentation checks, in pre-order.
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

    internal static IEnumerable<DependencyObject> LogicalAndVisualTree(DependencyObject root)
    {
        // WPF can expose the same child through both trees.
        var visited = new HashSet<DependencyObject>(ReferenceEqualityComparer.Instance);
        foreach (var node in Visit(root)) yield return node;

        IEnumerable<DependencyObject> Visit(DependencyObject node)
        {
            if (!visited.Add(node)) yield break;
            yield return node;
            foreach (object child in LogicalTreeHelper.GetChildren(node))
                if (child is DependencyObject dependency)
                    foreach (var item in Visit(dependency)) yield return item;
            if (node is Visual or System.Windows.Media.Media3D.Visual3D)
                for (int index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++)
                    foreach (var item in Visit(VisualTreeHelper.GetChild(node, index))) yield return item;
        }
    }
}
