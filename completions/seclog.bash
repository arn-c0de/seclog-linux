# bash completion for seclog, seclog-update and seclog-diagnose.
# Installed by install.sh under each of those names in
# ~/.local/share/bash-completion/completions/, where bash-completion loads it
# on demand.

_seclog_words() {
    local cur="$1"; shift
    # shellcheck disable=SC2207  # word list is static, no globbing risk
    COMPREPLY=($(compgen -W "$*" -- "$cur"))
}

_seclog_update() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
    if [[ $prev == --channel ]]; then
        _seclog_words "$cur" release branch
    else
        _seclog_words "$cur" --yes --channel --help
    fi
}

_seclog_diagnose() {
    _seclog_words "${COMP_WORDS[COMP_CWORD]}" --no-push --help
}

_seclog() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    if (( COMP_CWORD == 1 )); then
        _seclog_words "$cur" status diagnose update restart test-push version help --json --help --version
        return
    fi
    case "${COMP_WORDS[1]}" in
        status|--json) _seclog_words "$cur" --json --help ;;
        diagnose)      _seclog_diagnose ;;
        update)        _seclog_update ;;
        *)             COMPREPLY=() ;;
    esac
}

complete -F _seclog seclog
complete -F _seclog_update seclog-update
complete -F _seclog_diagnose seclog-diagnose
