# zsh-gitsync

Send and receive local git changes between machines using Tailscale.

## Installation

### oh-my-zsh

```bash
git clone https://github.com/f0e/zsh-gitsync.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-gitsync
```

Add `zsh-gitsync` to your plugins in `.zshrc`:
```bash
plugins=(... zsh-gitsync)
```

### antidote/antibody

Add to your `.zsh_plugins.txt`:
```
f0e/zsh-gitsync
```

### zinit

```bash
zinit load "f0e/zsh-gitsync"
```

### zplug

```bash
zplug "f0e/zsh-gitsync"
```

### Manual

```bash
git clone https://github.com/f0e/zsh-gitsync.git ~/.config/zsh/plugins/zsh-gitsync
echo "source ~/.config/zsh/plugins/zsh-gitsync/zsh-gitsync.plugin.zsh" >> ~/.zshrc
```

## Requirements

- `git`
- `jq` 
- `tailscale`

## Usage

Send changes to another machine:

```bash
gitsend tailscale-machine-name
```

Receive and apply changes:

```bash
gitrecv
```
