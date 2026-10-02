# Kobold NixOS

Host NixOS 26.05 para IA, agentes, containers de desenvolvimento e máquinas virtuais.
Sem flakes, Home Manager ou módulos Nix externos.

- Niri como único compositor, com login pelo Ly.
- Alacritty como terminal; Thunar como gerenciador de arquivos padrão.
- Noctalia v5 do canal stable (`pkgs.noctalia`), com agente Polkit nativo.
- Podman rootless e Distrobox; QEMU/KVM via libvirt e virt-manager.
- Flatpak e portal GTK para abrir, salvar e anexar arquivos.
- Portal GNOME mantido para compartilhamento de tela no Niri; sem Nautilus ou GNOME Keyring.

## Instalação e validação

`configuration.nix` importa `hardware-configuration.nix` local, gerado pelo instalador.
Não altere nem versione o arquivo de hardware. Instale `configuration.nix` em `/etc/nixos`,
ao lado do arquivo de hardware gerado pelo instalador.

Antes de ativar, no NixOS:

```sh
sudo nixos-rebuild build
sudo nixos-rebuild test
```

Esses comandos e os aliases `nx-*` usam a configuração instalada em `/etc/nixos`.
Para avaliar diretamente a cópia de Projetos, use `-I nixos-config=/caminho/configuration.nix`,
com o arquivo de hardware gerado presente ao lado.

Defina a senha de `kobold` antes do primeiro boot, conforme o comentário em `configuration.nix`.
O Ly pede autenticação; não há autologin.

## Sessão

`/etc/niri/config.kdl` fornece um padrão com teclado brasileiro, Alacritty e Thunar.
Um `~/.config/niri/config.kdl` existente tem precedência. Os comandos de IPC continuam
usando `noctalia msg ...`. Remova um eventual `spawn-at-startup "noctalia"` da configuração
pessoal, pois a sessão NixOS já inicia o shell por autostart.

O wrapper `kobold-noctalia` usa `~/.config/noctalia-nixos/noctalia` (ou o equivalente em
`XDG_CONFIG_HOME`). O arquivo padrão vem de `/etc/xdg/noctalia/nixos.toml` e habilita o
Polkit nativo. A aparência permanece editável no Noctalia. Não ative outro agente Polkit.
Evite habilitar o idle do Noctalia em paralelo à política declarada no sistema.
Configurações próprias e ajustes salvos pela interface podem sobrescrever os padrões.
A configuração anterior do Fedora não é modificada.

`Mod+Return` abre Alacritty, `Mod+E` abre Thunar e `Mod+L` bloqueia com gtklock.
O utilitário swayidle cuida de inatividade e suspensão; o compositor Sway não é instalado.
A tela bloqueia após 10 minutos e desliga após 11, com reativação ao retornar.

## Flatpak e desenvolvimento

Para habilitar Flathub somente para o usuário:

```sh
flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
```

Distrobox usa Podman. O usuário recebe mapeamentos UID/GID para containers rootless.
virt-manager conecta automaticamente a `qemu:///system`; ações administrativas usam Polkit.
Imagens de VMs devem ficar em armazenamento acessível ao usuário `qemu-libvirtd`, como
`/var/lib/libvirt/images`, em vez de pastas privadas do usuário.

IA e agentes podem rodar em containers/VMs; nenhum runtime, modelo ou servidor de IA
específico é instalado nesta configuração. A política de memória usa ZRAM sem swap em disco:
sob pressão elevada, processos, containers ou VMs podem ser encerrados por OOM.
Distrobox compartilha recursos do host; use VMs para agentes que exigem isolamento maior.
