import Foundation
import OmniWMIPC

enum CLICompletionGenerator {
    private static let commandAliasTokens: [[String]] = [
        ["focus-monitor", "previous"],
        ["switch-workspace", "previous"],
        ["switch-workspace", "back"],
    ]

    private static let queryAliasNames = ["monitors"]

    private static let queryFlagAliases: [IPCQuerySelectorName: [String]] = [
        .display: ["--monitor"],
    ]

    private static let subscribeFlags = ["--all", "--no-send-initial"]
    private static let watchFlags = ["--all", "--no-send-initial", "--exec"]

    static func script(for shell: CLIShell) -> String {
        switch shell {
        case .zsh:
            zshScript()
        case .bash:
            bashScript()
        case .fish:
            fishScript()
        }
    }

    private static func zshScript() -> String {
        """
        #compdef omniwmctl

        _omniwmctl() {
          local cur
          cur="${words[CURRENT]}"

          local suggestions=""
          if (( CURRENT == 2 )); then
            suggestions="\(shellWords(topLevelCommands))"
            compadd -- ${=suggestions}
            return
          fi

          case "${words[2]}" in
            query)
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(queryNames))"
              else
                local query_name="${words[3]}"
                [[ "$query_name" == "monitors" ]] && query_name="displays"
                local prev="${words[CURRENT-1]}"
                if [[ "$prev" == "--fields" ]]; then
                  case "$query_name" in
                    \(renderZshCase(map: queryFieldsByName))
                  esac
                else
                  case "$query_name" in
                    \(renderZshCase(map: queryFlagsByName))
                  esac
                fi
              fi
              ;;
            command)
              local first="${words[3]}"
              local second="${words[4]}"
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(commandFirstWords))"
              elif (( CURRENT == 4 )); then
                case "$first" in
                  \(renderZshCase(map: commandSlotThreeSuggestionsByFirst))
                esac
              elif (( CURRENT == 5 )); then
                case "$first $second" in
                  \(renderZshCase(map: commandSlotFourSuggestionsByPath))
                  *)
                    case "$first" in
                      \(renderZshCase(map: commandSlotFourFallbackByFirst))
                    esac
                    ;;
                esac
              elif (( CURRENT == 6 )); then
                case "$first $second" in
                  \(renderZshCase(map: commandSlotFiveSuggestionsByPath))
                esac
              fi
              ;;
            rule)
              if (( CURRENT == 3 )); then
                suggestions="\(shellWords(ruleActionNames))"
              elif [[ "${words[3]}" == "apply" ]]; then
                local prev="${words[CURRENT-1]}"
                if [[ "$prev" != "--window" && "$prev" != "--pid" ]]; then
                  suggestions="\(shellWords(ruleApplyFlags))"
                fi
              fi
              ;;
            subscribe)
              if [[ " ${words[*]} " != *" --exec "* ]]; then
                suggestions="\(shellWords(sortedUnique(subscriptionNames + subscribeFlags)))"
              fi
              ;;
            watch)
              if [[ " ${words[*]} " != *" --exec "* ]]; then
                suggestions="\(shellWords(sortedUnique(subscriptionNames + watchFlags)))"
              fi
              ;;
            workspace)
              suggestions="\(shellWords(workspaceActionNames))"
              ;;
            window)
              suggestions="\(shellWords(windowActionNames))"
              ;;
            completion)
              suggestions="zsh bash fish"
              ;;
          esac

          [[ -n "$suggestions" ]] && compadd -- ${=suggestions}
        }

        _omniwmctl "$@"
        """
    }

    private static func bashScript() -> String {
        """
        _omniwmctl()
        {
          local cur prev command first second query_name suggestions
          COMPREPLY=()
          cur="${COMP_WORDS[COMP_CWORD]}"
          prev="${COMP_WORDS[COMP_CWORD-1]}"
          command="${COMP_WORDS[1]}"

          __omniwmctl_compgen() {
            COMPREPLY=( $(compgen -W "$1" -- "$cur") )
          }

          if [[ ${COMP_CWORD} -eq 1 ]]; then
            __omniwmctl_compgen "\(shellWords(topLevelCommands))"
            return 0
          fi

          case "$command" in
            query)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(queryNames))"
                return 0
              fi

              query_name="${COMP_WORDS[2]}"
              [[ "$query_name" == "monitors" ]] && query_name="displays"
              suggestions=""
              if [[ "$prev" == "--fields" ]]; then
                case "$query_name" in
                  \(renderBashCase(map: queryFieldsByName))
                esac
              else
                case "$query_name" in
                  \(renderBashCase(map: queryFlagsByName))
                esac
              fi
              __omniwmctl_compgen "$suggestions"
              return 0
              ;;
            command)
              first="${COMP_WORDS[2]}"
              second="${COMP_WORDS[3]}"
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(commandFirstWords))"
                return 0
              elif [[ ${COMP_CWORD} -eq 3 ]]; then
                suggestions=""
                case "$first" in
                  \(renderBashCase(map: commandSlotThreeSuggestionsByFirst))
                esac
                __omniwmctl_compgen "$suggestions"
                return 0
              elif [[ ${COMP_CWORD} -eq 4 ]]; then
                suggestions=""
                case "$first $second" in
                  \(renderBashCase(map: commandSlotFourSuggestionsByPath))
                  *)
                    case "$first" in
                      \(renderBashCase(map: commandSlotFourFallbackByFirst))
                    esac
                    ;;
                esac
                __omniwmctl_compgen "$suggestions"
                return 0
              elif [[ ${COMP_CWORD} -eq 5 ]]; then
                suggestions=""
                case "$first $second" in
                  \(renderBashCase(map: commandSlotFiveSuggestionsByPath))
                esac
                __omniwmctl_compgen "$suggestions"
                return 0
              fi
              ;;
            rule)
              if [[ ${COMP_CWORD} -eq 2 ]]; then
                __omniwmctl_compgen "\(shellWords(ruleActionNames))"
                return 0
              fi
              if [[ "${COMP_WORDS[2]}" == "apply" && "$prev" != "--window" && "$prev" != "--pid" ]]; then
                __omniwmctl_compgen "\(shellWords(ruleApplyFlags))"
                return 0
              fi
              ;;
            subscribe)
              if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
                __omniwmctl_compgen "\(shellWords(sortedUnique(subscriptionNames + subscribeFlags)))"
                return 0
              fi
              ;;
            watch)
              if [[ " ${COMP_WORDS[*]} " != *" --exec "* ]]; then
                __omniwmctl_compgen "\(shellWords(sortedUnique(subscriptionNames + watchFlags)))"
                return 0
              fi
              ;;
            workspace)
              __omniwmctl_compgen "\(shellWords(workspaceActionNames))"
              return 0
              ;;
            window)
              __omniwmctl_compgen "\(shellWords(windowActionNames))"
              return 0
              ;;
            completion)
              __omniwmctl_compgen "zsh bash fish"
              return 0
              ;;
          esac
        }

        complete -F _omniwmctl omniwmctl
        """
    }

    private static func fishScript() -> String {
        let helperFunctions = """
        function __omniwmctl_prev_arg_is
            set -l tokens (commandline -opc)
            test (count $tokens) -gt 0; or return 1
            set -l prev $tokens[-1]
            contains -- $prev $argv
        end
        """

        let baseLines = topLevelCommands.map { command in
            "complete -c omniwmctl -f -n '__fish_use_subcommand' -a '\(command)'"
        }
        let queryLines = queryNames.map { query in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from query' -a '\(query)'"
        }
        let queryFlagLines = queryFlagsByName.flatMap { queryName, flags in
            flags.map { flag in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from query; and __fish_seen_subcommand_from \(queryName)' -a '\(flag)'"
            }
        }
        let queryFieldLines = queryFieldsByName.flatMap { queryName, fields in
            fields.map { field in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from query; and __fish_seen_subcommand_from \(queryName); and __omniwmctl_prev_arg_is --fields' -a '\(field)'"
            }
        }
        let commandRootLines = commandFirstWords.map { word in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command' -a '\(word)'"
        }
        let commandNestedLines = commandSlotThreeSuggestionsByFirst.flatMap { first, suggestions in
            suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(first)' -a '\(suggestion)'"
            }
        }
        let commandPathArgumentLines = commandSlotFourSuggestionsByPath.flatMap { path, suggestions in
            let pathWords = path.split(separator: " ").map(String.init)
            guard pathWords.count == 2 else { return [String]() }
            return suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(pathWords[0]); and __fish_seen_subcommand_from \(pathWords[1])' -a '\(suggestion)'"
            }
        }
        let commandFallbackLines = commandSlotFourFallbackByFirst.flatMap { first, suggestions in
            suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(first)' -a '\(suggestion)'"
            }
        }
        let commandSecondArgumentLines = commandSlotFiveSuggestionsByPath.flatMap { path, suggestions in
            let pathWords = path.split(separator: " ").map(String.init)
            guard pathWords.count == 2 else { return [String]() }
            return suggestions.map { suggestion in
                "complete -c omniwmctl -f -n '__fish_seen_subcommand_from command; and __fish_seen_subcommand_from \(pathWords[0]); and __fish_seen_subcommand_from \(pathWords[1])' -a '\(suggestion)'"
            }
        }
        let ruleLines = ruleActionNames.map { action in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from rule' -a '\(action)'"
        }
        let ruleApplyLines = ruleApplyFlags.map { flag in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from rule; and __fish_seen_subcommand_from apply' -a '\(flag)'"
        }
        let subscribeLines = sortedUnique(subscriptionNames + subscribeFlags).map { token in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from subscribe' -a '\(token)'"
        }
        let watchLines = sortedUnique(subscriptionNames + watchFlags).map { token in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from watch' -a '\(token)'"
        }
        let workspaceLines = workspaceActionNames.map { action in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from workspace' -a '\(action)'"
        }
        let windowLines = windowActionNames.map { action in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from window' -a '\(action)'"
        }
        let shellLines = CLIShell.allCases.map { shell in
            "complete -c omniwmctl -f -n '__fish_seen_subcommand_from completion' -a '\(shell.rawValue)'"
        }

        return (
            [helperFunctions]
                + baseLines
                + queryLines
                + queryFlagLines.sorted()
                + queryFieldLines.sorted()
                + commandRootLines
                + commandNestedLines.sorted()
                + commandPathArgumentLines.sorted()
                + commandFallbackLines.sorted()
                + commandSecondArgumentLines.sorted()
                + ruleLines
                + ruleApplyLines
                + subscribeLines
                + watchLines
                + workspaceLines
                + windowLines
                + shellLines
        )
        .joined(separator: "\n")
    }

    private static var topLevelCommands: [String] {
        ["ping", "version", "help", "completion", "command", "query", "rule", "workspace", "window", "subscribe", "watch"]
    }

    private static var queryNames: [String] {
        sortedUnique(IPCAutomationManifest.queryDescriptors.map(\.name.rawValue) + queryAliasNames)
    }

    private static var subscriptionNames: [String] {
        IPCSubscriptionChannel.allCases.map(\.rawValue)
    }

    private static var ruleActionNames: [String] {
        IPCAutomationManifest.ruleActionDescriptors.map(\.name.rawValue)
    }

    private static var ruleApplyFlags: [String] {
        IPCAutomationManifest.ruleActionDescriptor(for: .apply)?.options.map(\.flag) ?? []
    }

    private static var workspaceActionNames: [String] {
        IPCAutomationManifest.workspaceActionDescriptors.map(\.name.rawValue)
    }

    private static var windowActionNames: [String] {
        IPCAutomationManifest.windowActionDescriptors.map(\.name.rawValue)
    }

    private static var commandFirstWords: [String] {
        sortedUnique(IPCAutomationManifest.commandDescriptors.compactMap { $0.commandWords.first })
    }

    private static var commandSlotThreeSuggestionsByFirst: [String: [String]] {
        var map: [String: Set<String>] = [:]

        for descriptor in IPCAutomationManifest.commandDescriptors {
            guard let first = descriptor.commandWords.first else { continue }
            if descriptor.commandWords.count > 1 {
                map[first, default: []].insert(descriptor.commandWords[1])
            }
            if let literals = literalValues(for: descriptor.arguments.first?.kind) {
                map[first, default: []].formUnion(literals)
            }
        }

        for alias in commandAliasTokens where alias.count > 1 {
            map[alias[0], default: []].insert(alias[1])
        }

        return map.mapValues { Array($0).sorted() }
    }

    private static var commandSlotFourSuggestionsByPath: [String: [String]] {
        commandArgumentSuggestionsByPath(argumentIndex: 0, commandWordCount: 2)
    }

    private static var commandSlotFourFallbackByFirst: [String: [String]] {
        var map: [String: Set<String>] = [:]
        for descriptor in IPCAutomationManifest.commandDescriptors where descriptor.commandWords.count == 1 {
            guard descriptor.arguments.count > 1,
                  let literals = literalValues(for: descriptor.arguments[1].kind),
                  let first = descriptor.commandWords.first
            else {
                continue
            }
            map[first, default: []].formUnion(literals)
        }
        return map.mapValues { Array($0).sorted() }
    }

    private static var commandSlotFiveSuggestionsByPath: [String: [String]] {
        commandArgumentSuggestionsByPath(argumentIndex: 1, commandWordCount: 2)
    }

    private static func commandArgumentSuggestionsByPath(
        argumentIndex: Int,
        commandWordCount: Int
    ) -> [String: [String]] {
        var map: [String: Set<String>] = [:]
        for descriptor in IPCAutomationManifest.commandDescriptors where descriptor.commandWords.count == commandWordCount {
            guard descriptor.arguments.count > argumentIndex,
                  let literals = literalValues(for: descriptor.arguments[argumentIndex].kind)
            else {
                continue
            }
            map[pathKey(descriptor.commandWords), default: []].formUnion(literals)
        }
        return map.mapValues { Array($0).sorted() }
    }

    private static var queryFlagsByName: [String: [String]] {
        var map: [String: [String]] = [:]
        for descriptor in IPCAutomationManifest.queryDescriptors {
            let flags = sortedUnique(selectorFlags(for: descriptor) + (descriptor.fields.isEmpty ? [] : ["--fields"]))
            map[descriptor.name.rawValue] = flags
        }
        map["monitors"] = map[IPCQueryName.displays.rawValue] ?? []
        return map
    }

    private static var queryFieldsByName: [String: [String]] {
        var map = Dictionary(
            uniqueKeysWithValues: IPCAutomationManifest.queryDescriptors.map { descriptor in
                (descriptor.name.rawValue, descriptor.fields)
            }
        )
        map["monitors"] = map[IPCQueryName.displays.rawValue] ?? []
        return map
    }

    private static func selectorFlags(for descriptor: IPCQueryDescriptor) -> [String] {
        var flags = descriptor.selectors.map(\.name.flag)
        if descriptor.selectors.contains(where: { $0.name == .display }) {
            flags.append(contentsOf: queryFlagAliases[.display] ?? [])
        }
        return flags
    }

    private static func literalValues(for kind: IPCCommandArgumentKind?) -> [String]? {
        guard let kind else { return nil }
        switch kind {
        case .direction:
            return ["left", "right", "up", "down"]
        case .layout:
            return ["default", "niri", "dwindle"]
        case .resizeOperation:
            return ["grow", "shrink"]
        case .workspaceNumber, .columnIndex:
            return nil
        }
    }

    private static func pathKey(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    private static func renderZshCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                            suggestions="\(shellWords(map[key] ?? []))"
                            ;;
            """
        }
        .joined(separator: "\n                  ")
    }

    private static func renderBashCase(map: [String: [String]]) -> String {
        map.keys.sorted().map { key in
            """
            \(quotedCasePattern(key)))
                  suggestions="\(shellWords(map[key] ?? []))"
                  ;;
            """
        }
        .joined(separator: "\n                ")
    }

    private static func quotedCasePattern(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private static func shellWords(_ words: [String]) -> String {
        sortedUnique(words).joined(separator: " ")
    }
}
