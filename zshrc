ZSH=$HOME/.oh-my-zsh
ZSH_THEME="robbyrussell"
plugins=(git gitfast last-working-dir common-aliases zsh-syntax-highlighting history-substring-search)

# Homebrew: no analytics
export HOMEBREW_NO_ANALYTICS=1

# Skip oh-my-zsh's insecure-directory warning
ZSH_DISABLE_COMPFIX=true

source "${ZSH}/oh-my-zsh.sh"
unalias rm 2>/dev/null   # common-aliases makes rm interactive; undo that

# pyenv (no-op if not installed)
export PYENV_VIRTUALENV_DISABLE_PROMPT=1
type -a pyenv > /dev/null && eval "$(pyenv init -)" && eval "$(pyenv virtualenv-init - 2> /dev/null)" && RPROMPT+='[🐍 $(pyenv version-name)]'

# nvm (no-op if not installed)
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# Auto `nvm use` in folders with a .nvmrc
autoload -U add-zsh-hook
load-nvmrc() {
  if nvm -v &> /dev/null; then
    local node_version="$(nvm version)"
    local nvmrc_path="$(nvm_find_nvmrc)"
    if [ -n "$nvmrc_path" ]; then
      local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")
      if [ "$nvmrc_node_version" = "N/A" ]; then
        nvm install
      elif [ "$nvmrc_node_version" != "$node_version" ]; then
        nvm use --silent
      fi
    elif [ "$node_version" != "$(nvm version default)" ]; then
      nvm use default --silent
    fi
  fi
}
type -a nvm > /dev/null && add-zsh-hook chpwd load-nvmrc
type -a nvm > /dev/null && load-nvmrc

# Personal aliases
[[ -f "$HOME/.aliases" ]] && source "$HOME/.aliases"

# Locale
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Editor: VS Code where installed, nano otherwise
command -v code >/dev/null && export EDITOR=code || export EDITOR=nano

# Added by LM Studio CLI (lms)
export PATH="$PATH:/Users/broto/.lmstudio/bin"
# End of LM Studio CLI section

# Local tools (paths that don't exist on a machine are harmless)
export PATH="$HOME/.local/bin:$PATH"
export OCR_BIN="$HOME/projects/webtools/tools/ocr"
export WHISPER_BIN="/opt/homebrew/bin/whisper-cli"
export WHISPER_MODEL="$HOME/models/whisper/ggml-large-v3-turbo.bin"
export WHISPER_VAD="$HOME/models/whisper/ggml-silero-v5.1.2.bin"

# Air → Mini: mosh into moon's persistent tmux session
alias moon='mosh --server=/opt/homebrew/bin/mosh-server moon -- /opt/homebrew/bin/tmux new -A -s main'

# Agent shells never inherit interactive aliases. Claude Code exports CLAUDECODE=1; an
# aliased `cp -i` in a headless shell prompts nobody, silently does nothing, and reports
# success — which is how a restore-over-existing-file no-opped on 2026-08-02 and left a
# deliberately broken value in a content file. Adding -f does not help: the alias wins.
# Must stay last — ~/.aliases is sourced above.
[[ -n "$CLAUDECODE" ]] && unalias -m '*'
