# Código e arquitetura

## Stack real

| Parte | Tecnologia | Versão observada |
|---|---|---|
| Aplicativo | Windows PowerShell 5.1 + WinForms (`RcloneDriveManager.ps1`) | 1.1.4 |
| Inicializador | C# .NET Framework 4, `csc.exe` x64, subsistema GUI | 1.1.4 |
| Acesso ao SharePoint | rclone `onedrive` (`drive_type=documentLibrary`) via `rclone rcd` | 1.75.1 |
| Sistema de arquivos | WinFsp (`cmount`, `network_mode`) | 2.2.26215 (v2.2B4) |
| Instaladores | WiX Toolset (MSI por máquina + bundle `Setup.exe`) | 4.0.6 |
| API | Microsoft Graph v1.0 (sites, bibliotecas, metadados de itens) | — |

Não há banco de dados, servidor próprio nem interface web.

## Mapa do código

```
RcloneDriveManager.ps1        aplicativo completo (3.4 mil linhas, ver Dívida)
installer/src/Launcher.cs     ponto de entrada GUI: valida argumentos e chama o .ps1
installer/src/Product.wxs     MSI: arquivos, menu de contexto, verbos de duplo clique, atalhos
installer/src/Bundle.wxs      Setup.exe: WinFsp + MSI
installer/scripts/            build, staging com hash fixado e teste estático do layout
installer/config/             manifestos com versão e SHA-256 do rclone e do WinFsp
tests/                        testes isolados (Graph simulado) e do inicializador
scripts/check.ps1             verificação canônica (lint + testes)
```

Seções de `RcloneDriveManager.ps1`, na ordem do arquivo:

| Seção | Funções principais | Responsabilidade |
|---|---|---|
| Log e observador | `Protect-LogMessage`, `Write-AppLog`, `Invoke-ShellWatcher` | Log sem segredos; avisar o Explorador sobre pastas alteradas |
| Segredos e config | `Protect-LocalSecret`, `Get-OrCreateConfigPassword`, `Initialize-AppConfigEncryption` | Senha do `rclone.conf` protegida por DPAPI; ACL privada |
| Controlador rclone | `Start-Controller`, `Invoke-ControllerRequest` | `rclone rcd` em 127.0.0.1 com usuário/senha aleatórios |
| Configurações | `Load-Settings`, `Save-Settings`, `ConvertTo-SafeProfile` | `settings.json` validado, com cópia de segurança |
| Graph e documentos | `Get-DocumentTarget`, `Invoke-DocumentAction`, `Get-OfficeDocumentUri` | Resolver caminho → item; duplo clique pelo SharePoint e "Abrir no SharePoint" |
| Montagem | `New-MountRequest`, `Start-Mount`, `Stop-Mount`, `Wait-PendingUploads` | Opções do VFS; não desmontar com envio pendente |
| Interface | `Show-NewSharePointMappingDialog`, `Build-MainForm` | Janelas WinForms |
| Entrada | bloco final do arquivo | Mutex por usuário, `-AutoMount`, `-SelfTest`, `-ShellWatcher`, `-DocumentAction` |

## Fronteiras e fluxo

- **Explorador → app:** os verbos do registro chamam `SharePointFacil.exe`
  com argumentos fixos (`-DocumentAction`, `-OfficeOpen "%1"`). O
  inicializador recusa qualquer outro argumento e decide em milissegundos se
  o arquivo está numa letra mapeada; fora dela, entrega ao verbo `Open` do
  Office.
- **App → rclone:** só pela API RC local (`Invoke-ControllerRequest`),
  autenticada, e só depois de `Test-ControllerIdentity` confirmar que a porta
  pertence ao rclone iniciado pelo app; o token OAuth fica no `rclone.conf`
  criptografado.
- **App → Graph:** só `graph.microsoft.com` por HTTPS, com o token do remote
  da própria biblioteca (`Get-ProfileAccessToken`); POST sem repetição
  automática.
- **App → OneDrive:** `Get-OneDriveSyncUri` lê `sharePointIds` do drive no
  Graph e abre `odopen://sync/?siteId={…}&webId={…}&listId={…}&userEmail=…&webUrl=…&webTitle=…&listTitle=…`,
  o mesmo link do botão Sincronizar do SharePoint (formato não documentado
  oficialmente; validado com o cliente OneDrive em 23/10/2026). Depois disso
  a sincronização é do OneDrive; o app não a acompanha.
- **Atalho no OneDrive:** `Add-OneDriveShortcut` faz `POST /me/drive/root/children`
  com `remoteItem` apontando para a raiz da biblioteca e `conflictBehavior=fail`
  (API documentada do OneDrive; validada no OneDrive for Business em
  27/10/2026). O OneDrive prefixa o nome do site; 409 `nameAlreadyExists`
  indica nome em uso e 409 `notAllowed`, atalho no mesmo local ou acima.
- **Subpasta:** a árvore da janela de bibliotecas lista um nível por vez
  (`Get-LibraryFolderList`). A pasta escolhida vira `folder` no perfil e a
  unidade monta `remote:Pasta/Sub` (`Get-ProfileMountSource`); `Get-DocumentTarget`
  soma essa pasta ao caminho. O atalho aponta para o item da pasta. A
  sincronização acrescenta `folderId={listItemUniqueId}`, `folderUrl` e
  `folderName` ao link `odopen://sync` (não documentado; validado com o
  cliente OneDrive em 27/10/2026, que sincronizou só a pasta).
- **Concorrência:** não há trava compartilhada entre a janela e o Explorador;
  as ações de documento só leem dados, e comandos simultâneos do Explorador
  são enfileirados pela trava do processo (`-DocumentCommand`).
- **Identidade da conta:** o app OAuth do rclone não concede `User.Read`,
  então `/me` responde 403. O login (`upn`) vem das claims do token
  (`Get-TokenAccountName`).
- **App → Office:** URIs `ms-word:ofe|u|<webDavUrl>`; a URL é validada contra
  o host da biblioteca (`Get-TrustedDocumentUrl`).
- Dados locais: `%LOCALAPPDATA%\SharePointFacil` (configurações, cache VFS,
  logs).
- **Explorador → app:** além do duplo clique, um único verbo "Abrir no
  SharePoint" (sem submenu) em arquivos e pastas. Reservas próprias
  (checkout/check-in pelo app) foram removidas na 1.1.6; o Office faz isso.

## Decisões

| Decisão | Motivo | Fonte/data | Revisitar quando |
|---|---|---|---|
| rclone + WinFsp em vez da Cloud Files API | Protocolo, cache e envio prontos; lista sob demanda | Análise de 23/10/2026 | Clientes exigirem ícones de estado ou arquivos offline |
| `IgnoreSize`/`IgnoreChecksum` no mount | O SharePoint regrava arquivos Office no envio | Teste em biblioteca real, 23/10/2026 | O rclone tratar isso de forma nativa |
| `dir_cache_time=24h` + `poll_interval=15s` | A API delta invalida o cache; pastas grandes não são relidas | [AUDITORIA](../AUDITORIA-RCLONE-SHAREPOINT.md) | Notificações de mudança falharem |
| Duplo clique por verbo padrão no HKLM | Um padrão em HKCU sem o verbo quebra o duplo clique após desinstalar | Teste de shell, 23/10/2026 | Office ou Windows mudarem associações |
| Office abre por `webDavUrl` | O `webUrl` aponta para o visualizador web (`Doc.aspx`) | Teste real, 23/10/2026 | — |

Detalhes do backend: [AUDITORIA-RCLONE-SHAREPOINT.md](../AUDITORIA-RCLONE-SHAREPOINT.md).
Fluxos de documento: [DOCUMENTOS-OFFICE.md](../DOCUMENTOS-OFFICE.md).
Instalador: [installer/README.md](../installer/README.md).

## Dívida conhecida

`RcloneDriveManager.ps1` tem cerca de 3.400 linhas, contra a referência de
350 do toolkit. A divisão por responsabilidade (seções acima, em módulos
`.ps1` com dot-source) deve ser uma entrega própria: o MSI empacota um único
script e os testes carregam funções pelo AST desse arquivo, então a divisão
muda o staging, o layout do MSI e os testes juntos. Sem prazo definido.

## Manutenção

Atualize este mapa quando arquivos, dependências, fronteiras ou decisões
mudarem. Remova decisões que deixarem de valer.
