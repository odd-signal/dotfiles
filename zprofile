[[ -f ~/.profile ]] && emulate sh -c '. ~/.profile'

# Setup the PATH for pyenv binaries and shims
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
type -a pyenv > /dev/null && eval "$(pyenv init --path)"
eval "$(/opt/homebrew/bin/brew shellenv)"

# Created by `pipx` on 2026-04-27 09:42:36
export PATH="$PATH:/Users/broto/.local/bin"
