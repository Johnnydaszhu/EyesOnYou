import Foundation

// Top-level entry (executable target; avoid @main + free functions conflict).
let code = CLIRunner.run(args: Array(CommandLine.arguments.dropFirst()))
exit(Int32(code.rawValue))
