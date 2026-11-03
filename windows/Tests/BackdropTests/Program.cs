using System;
using System.IO;
using System.Windows;
using CodexPacer.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 2 || args[0] is not ("scene" or "overlay" or "cpu" or "interactive" or "input" or "motion")) return 2;
        string output = Path.GetFullPath(args[1]); Directory.CreateDirectory(output);
        int result = 1;
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown,
            Resources = new ResourceDictionary { Source = new Uri("/CodexPacer;component/PacerTheme.xaml", UriKind.Relative) } };
        app.DispatcherUnhandledException += (_, error) => { File.WriteAllText(Path.Combine(output, "failure.txt"), error.Exception.ToString()); error.Handled = true; app.Shutdown(1); };
        app.Startup += async (_, _) =>
        {
            try
            {
                if (args[0] == "scene") { result = 0; SyntheticScene.Show(output); return; }
                if (args[0] == "cpu") await CpuProbe.Run(output);
                else if (args[0] == "motion") await MotionProbe.Run(output);
                else await OverlayProbe.Run(output, args[0] == "interactive", args[0] == "input");
                result = 0;
            }
            catch (Exception error) { File.WriteAllText(Path.Combine(output, "failure.txt"), error.ToString()); }
            finally { if (args[0] != "scene") app.Shutdown(); }
        };
        app.Run(); return result;
    }
}
