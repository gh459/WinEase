using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace WinEaseGui;

// Lays its children out left to right and starts a new row when the next child does not fit, so a row of
// buttons never leaves the window (WinUI 3 has no WrapPanel; VariableSizedWrapGrid gives every cell the size
// of the first child and cuts longer texts). Every child keeps its own size. With unlimited width (an Auto
// column) everything stays in one row.
public sealed class WrapPanel : Panel
{
    public double HorizontalSpacing { get; set; }
    public double VerticalSpacing { get; set; }

    protected override Size MeasureOverride(Size availableSize)
    {
        double maxWidth = availableSize.Width;
        double x = 0, rowHeight = 0, usedWidth = 0, totalHeight = 0;
        foreach (UIElement child in Children)
        {
            child.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Size s = child.DesiredSize;
            if (x > 0 && x + s.Width > maxWidth)
            {
                totalHeight += rowHeight + VerticalSpacing;
                x = 0;
                rowHeight = 0;
            }
            x += s.Width + HorizontalSpacing;
            rowHeight = Math.Max(rowHeight, s.Height);
            usedWidth = Math.Max(usedWidth, x - HorizontalSpacing);
        }
        totalHeight += rowHeight;
        return new Size(double.IsInfinity(maxWidth) ? usedWidth : Math.Min(usedWidth, maxWidth), totalHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, rowHeight = 0;
        foreach (UIElement child in Children)
        {
            Size s = child.DesiredSize;
            if (x > 0 && x + s.Width > finalSize.Width)
            {
                y += rowHeight + VerticalSpacing;
                x = 0;
                rowHeight = 0;
            }
            child.Arrange(new Rect(x, y, Math.Min(s.Width, Math.Max(finalSize.Width, 0)), s.Height));
            x += s.Width + HorizontalSpacing;
            rowHeight = Math.Max(rowHeight, s.Height);
        }
        return finalSize;
    }
}
