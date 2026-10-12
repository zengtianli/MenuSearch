import AppKit

// One executable, three entries: the application (Finder, login, or started by the command when nothing listens),
// the `menusearch` command, and the offscreen self-test. An unknown command is a usage error; it never opens a panel.
let arguments = Array(CommandLine.arguments.dropFirst())
#if APP_STORE
if arguments.first == "--store-self-test" { StoreSelfTest.run() }
#else
if arguments.first == "--self-test" { SelfTest.run(arguments: arguments) }
if arguments.first == "--site-shots" { SelfTest.siteShots(arguments: arguments) }
#endif
// `-lane_quiet YES`: the hidden cold-start measurement of a copy of the application (shared LaneSignal contract).
if LaneSignal.quiet { AppMain.run(arguments: arguments, measuring: true) }

#if APP_STORE
if arguments.isEmpty || arguments.first?.hasPrefix("--app-") == true || arguments.first?.hasPrefix("-psn_") == true {
    AppMain.run(arguments: arguments)
}
fputs("MenuSearch 的 Mac App Store 版不提供命令行入口。\n", stderr)
exit(2)
#else
let invokedAsCommand = (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "") == "menusearch"
let launchedBare = arguments.isEmpty && !invokedAsCommand && isatty(STDIN_FILENO) == 0
if launchedBare || arguments.first?.hasPrefix("--app-") == true || arguments.first?.hasPrefix("-psn_") == true {
    AppMain.run(arguments: arguments)
}
exit(CLI.run(arguments))
#endif
