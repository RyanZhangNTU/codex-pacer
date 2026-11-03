// Synthetic PE version-resource fixture. Tests inspect it without executing it.
System.IO.File.WriteAllText(System.IO.Path.Combine(System.AppContext.BaseDirectory, "fixture-was-launched"), "unexpected launch");
