import AppKit

// One executable, three entries: the application (Finder, login, or started by the command when nothing listens),
// the `menusearch` command, and the offscreen self-test. An unknown command is a usage error; it never opens a panel.
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--self-test" { SelfTest.run(arguments: arguments) }
if arguments.first == "--site-shots" { SelfTest.siteShots(arguments: arguments) }
// `-lane_quiet YES`: the hidden cold-start measurement of a copy of the application (shared LaneSignal contract).
if LaneSignal.quiet { AppMain.run(arguments: arguments, measuring: true) }

let invokedAsCommand = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "") == "menusearch"
let launchedBare = arguments.isEmpty && !invokedAsCommand && isatty(STDIN_FILENO) == 0
if launchedBare || arguments.first?.hasPrefix("--app-") == true || arguments.first?.hasPrefix("-psn_") == true {
    AppMain.run(arguments: arguments)
}
exit(CLI.run(arguments))
