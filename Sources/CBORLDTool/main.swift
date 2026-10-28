import CBORLDCommandLine
import Foundation

exit(await CommandLineTool.run(Array(CommandLine.arguments.dropFirst())))
