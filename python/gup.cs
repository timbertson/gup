using System;
using System.IO;
using System.Reflection;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using System.Collections;
 
public class GupWrapper
{
	static string QuoteArguments(IList args) {
		// adopted from python's subprocess.list2cmdline function
		StringBuilder sb = new System.Text.StringBuilder();
		foreach (string arg in args) {
			int backslashes = 0;

			// Add a space to separate this argument from the others
			if (sb.Length > 0) {
				sb.Append(" ");
			}

			bool needquote = arg.Length == 0 || arg.Contains(" ") || arg.Contains("\t");
			if (needquote) {
				sb.Append('"');
			}

			foreach (char c in arg) {
				if (c == '\\') {
					// Don't know if we need to double yet.
					backslashes++;
				}
				else if (c == '"') {
					// Double backslashes.
					sb.Append(new String('\\', backslashes*2));
					backslashes = 0;
					sb.Append("\\\"");
				} else {
					// Normal char
					if (backslashes > 0) {
						sb.Append(new String('\\', backslashes));
						backslashes = 0;
					}
					sb.Append(c);
				}
			}

			// Add remaining backslashes, if any.
			if (backslashes > 0) {
				sb.Append(new String('\\', backslashes));
			}

			if (needquote) {
				sb.Append(new String('\\', backslashes));
				sb.Append('"');
			}
		}
		return sb.ToString();
	}

	static void Main(string[] args)
	{
		string here = Assembly.GetEntryAssembly().Location;
		string dir = Path.GetDirectoryName(here);
		string gup = Path.Combine(dir, "gup");

		ArrayList pythonArgs = new ArrayList(args);
		pythonArgs.Insert(0, gup);

		string argstr = QuoteArguments(pythonArgs);

		// System.Console.WriteLine(argstr);

		var p = Process.Start(new ProcessStartInfo ("python", argstr) { UseShellExecute = false });

		p.WaitForExit();
		Environment.Exit(p.ExitCode);
	}
}
