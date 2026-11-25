# Backpack Emacs

![Only compatible with GNU Emacs 29.1 and up](https://img.shields.io/badge/compatible-29.1%20and%20up-grey?style=for-the-badge&logo=gnuemacs&logoColor=white&logoSize=auto&label=GNU%20Emacs&labelColor=%237F5AB6) [![Radicle](https://img.shields.io/badge/Radicle-rad%3AzecRiY...haCzJh-purple?style=for-the-badge)](https://radicle.network/nodes/jardin.jorgearaya.dev/rad:zecRiYjpjFnZWFhygfVM7shaCzJh)
[![Backup on GitHub](https://img.shields.io/badge/Backup-GitHub-black?style=for-the-badge&logo=github)](https://github.com/shackra/backpack)

A self-documenting GNU Emacs starter kit inspired by [Bedrock](https://codeberg.org/ashton314/emacs-bedrock) and [Doom](https://github.com/doomemacs/doomemacs).

> [!IMPORTANT]
> **This GitHub repository is only a backup mirror.**  
> The **canonical repository** is on **Radicle**: `rad:zecRiYjpjFnZWFhygfVM7shaCzJh`
>
> Please submit **[issues](https://radicle.network/nodes/oak.radicle.garden/rad:zecRiYjpjFnZWFhygfVM7shaCzJh/issues) and [patches](https://radicle.network/nodes/oak.radicle.garden/rad:zecRiYjpjFnZWFhygfVM7shaCzJh/patches)** exclusively to the repository
> on the Radicle network.

> [!WARNING]  
> This starter kit is bare bones and in rapid development, things may not work, be missing or break in following releases.

This starter kit uses [leaf.el](https://github.com/conao3/leaf.el) as the DSL for the configuration and [elpaca](https://github.com/progfolio/elpaca) as package manager. There are macros and functions that help users defining what they want to use from the starter kit (much like in Doom; except I took some liberty to auto-turn on some features).

## Getting started

### Installing Backpack Emacs

Make a backup of your old Emacs configuration. Then, clone this repository either in your `$HOME` or in your `$XDG_CONFIG_HOME`. Regardless of where you decide to clone, please be sure to add the `bin/` directory to your PATH, otherwise your shell won't know where the `backpack` command is.

#### From Radicle

In case you didn't know, Radicle is a self-described *open source*, peer-to-peer code collaboration stack built on Git. Is a really cool project and I encourage you to check it out! You **don't need to have** a radicle node to clone Backpack from mine.

```sh
git clone --recurse-submodules https://oak.radicle.garden/rad%3AzecRiYjpjFnZWFhygfVM7shaCzJh ~/.emacs.d
```

#### From GitHub

```sh
git clone --recurse-submodules https://github.com/shackra/backpack.git ~/.emacs.d
```

### Writing your initial configuration

> [!IMPORTANT]
> You can learn what's available in Backpack with `backpack-inventory` (bound to `C-h I`).

Now that you have the starter kit cloned with its corresponding sub-modules (right?), you need to write your configuration. It has to go in either `$HOME/.backpack.d` or `$XDG_CONFIG_HOME/backpack`, in any of those two directories make a file called `init.el`:

```elisp
;; -*- no-byte-compile: t; -*-

(gear!
  :ui
  (theme modus-vivendi)
  :editing
  (go -treesit lsp)
  :config
  default)
```

This will tell Backpack Emacs what stuff you want to use. There are *pouches* (or categories, `:ui` for example) that store different *gear* (or modules, `theme` is gear). Gear can have extra features you may want to turn on (or off), Backpack Emacs expresses the existence of such additional features as *flags* (the *flag* of `theme` is `modus-vivendi`, the theme we want to use in the example above).

Some features are turned on by default if some gear is activated. To turn them off, simply put a dash in front of the flag (`-treesit` in the go gear, for example). Putting a dash in front of a flag that is activated only when explicitly used by the user does nothing.

### Please, run `backpack ensure` on a terminal every time you change your configuration

Please do the above. It helps speed up the initialization of Emacs and run functions that won't be called in a normal execution of Emacs. When running `backpack ensure` you are supposed to see the elpaca logging its progress, among many other things, and then Emacs exiting.

### Mermaid diagrams with Pele

Enable the `mermaid` gear under `:editing` to use Pele for `.mmd`/`.mermaid` editing. When the `org` gear is enabled too, Mermaid Org blocks get live SVG previews and Babel execution through Pele:

```elisp
(gear! :editing org mermaid)
```

`backpack ensure` provisions Pele's native renderer after installing the pinned Elisp package. It skips provisioning if Pele already resolves a compatible module; otherwise it tries to compile Pele's module with `make` using the same Emacs executable. A successful build is placed where the loaded Elpaca copy of Pele can find it. If compilation fails on a supported non-NixOS system, Backpack prints the build warning/output and tries Pele's verified prebuilt download (HTTPS and the system `tar` command are required). A failed fallback aborts `ensure` with an error. Startup itself does not compile or download anything.

On NixOS, Backpack never downloads Pele's prebuilt Linux artifact as a fallback. It reuses a module already resolved by Pele; if none is available, `ensure` attempts a local source build and reports the compiler output if it fails. Run `backpack ensure` in an environment that provides:

- GNU Make, a C compiler with pthreads, and Python 3.10 or newer;
- Emacs built with dynamic-module support and its `emacs-module.h` headers;
- optionally `pkg-config`, Pango and fontconfig for native text measurement (without Pango, Pele uses its width estimates).

For example, a Nix shell can supply `gnumake`, `gcc`, `python3`, `pkg-config`, `pango` and `fontconfig` while using the same Nix Emacs that Backpack runs. Pele vendors the renderer and QuickJS, so the build does not require Node.js, a browser or Mermaid CLI.

Upstream currently publishes prebuilt modules for macOS 12+ and Linux with glibc 2.35+ on ARM64 and x86-64; previews additionally require SVG image support. Pele upstream does not currently announce a Windows source build or prebuilt module. Because this gear no longer uses `mmdc`, `backpack ensure` fails with an unsupported-platform diagnostic on Windows or other unsupported systems.

### Finding out what is available in your Backpack

Press `C-h I` or run `M-x backpack-inventory` to browse all available pouches, gears and flags interactively. The inventory shows what's enabled in your configuration, what's available, and how to configure each feature -- including flags, external tools, required fonts, and pinned package versions.

## What's in the Backpack?

Backpack is self-documenting. Rather than maintaining a static list of features here, run `M-x backpack-inventory` (or `C-h I`) inside Emacs to see everything that's available. The inventory browser lets you navigate pouches, drill into gears, and inspect flags, external tool requirements, fonts, example `gear!` snippets, and pinned package refs -- all extracted automatically from the source code.

## Tips

### Email contexts with mu4e

If you enable the `:email mu4e` gear, you can use `backpack/mu4e-easy-context` to easily create your email account contexts in your configuration:

```elisp
(with-eval-after-load 'mu4e
  (setq mu4e-contexts `(,(backpack/mu4e-easy-context
                          :c-name "example"
                          :maildir "example-dir"
                          :mail "user@example.com"
                          :sig "Example signature"))))
```
