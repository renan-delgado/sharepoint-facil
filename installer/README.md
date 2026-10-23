# Instalador do SharePoint Fácil

Esta pasta gera dois artefatos x64 com WiX Toolset 4.0.6:

- `SharePointFacil-<versão>-x64.msi` instala o aplicativo por máquina em
  `C:\Program Files\SharePoint Fácil`, com o aplicativo, o ícone próprio e o
  `rclone.exe` 1.75.1 já integrado.
- `SharePointFacilSetup-<versão>-x64.exe` é o instalador recomendado. Ele
  mantém ou atualiza o WinFsp para 2.2.26215 e depois instala o aplicativo.

O usuário não precisa localizar o rclone nem configurar o WinFsp manualmente.
Depois da instalação, o fluxo esperado é:

1. Abrir **SharePoint Fácil** pelo menu Iniciar ou pela área de trabalho.
2. Clicar em **Conectar biblioteca**.
3. Entrar na conta Microsoft pelo navegador somente quando a autorização não
   existir ou tiver expirado.
4. Escolher uma biblioteca acessível, a letra da unidade, o nome exibido no
   Explorador e se ela deve ser reconectada no logon.
5. Conectar e usar a unidade pelo Explorador de Arquivos.

## Atalhos e reconexão no logon

O MSI cria e gerencia três atalhos comuns:

- menu Iniciar;
- área de trabalho;
- inicialização do Windows, com o argumento `-AutoMount`.

Os atalhos e a entrada em **Aplicativos instalados** usam o ícone do produto,
sem herdar o ícone genérico do `wscript.exe`.

O atalho de inicialização apenas abre o aplicativo em modo de reconexão. Cada
perfil de usuário continua decidindo quais bibliotecas devem ser reconectadas.
Como o atalho pertence ao MSI, reparo, atualização e desinstalação conseguem
restaurá-lo ou removê-lo corretamente.

As unidades são criadas na sessão do usuário. Por isso, o aplicativo deve ser
aberto normalmente, sem **Executar como administrador**.

## Dados por usuário

Configurações, cache, autorização Microsoft e logs ficam em
`%LOCALAPPDATA%\SharePointFacil`. O MSI não empacota nem apaga esses dados. Isso
preserva as conexões durante reparos, atualizações e reinstalações e evita que
tokens de um usuário sejam copiados para outro.

Na desinstalação, o MSI remove os arquivos instalados e os três atalhos. O
WinFsp permanece instalado porque pode ser compartilhado por outros programas.
Os dados em `%LOCALAPPDATA%\SharePointFacil` também são preservados; devem ser
apagados manualmente somente quando o usuário quiser remover suas conexões e
autorizações locais.

## Arquivos Office e manutenção

O aplicativo já monta as unidades com cache **VFS full** e tempo de write-back
adequado para gravação. Feche Word, Excel e PowerPoint antes de desmontar uma
unidade, remover uma conexão, atualizar, reparar ou desinstalar o produto. O
aplicativo mantém a unidade conectada quando ainda há cache sujo ou envio
pendente, evitando descartar alterações silenciosamente.

Antes de atualizar, reparar ou desinstalar, abra o SharePoint Fácil e desmonte
todas as unidades. Os atalhos chamam diretamente o Windows PowerShell assinado
pela Microsoft; o produto não instala nem executa arquivos VBS ou um launcher
auxiliar.

A coautoria simultânea do mesmo arquivo Office pela unidade do Explorador pode
gerar conflito de versões. Para edição simultânea, prefira abrir o arquivo pelo
SharePoint ou pelos aplicativos Microsoft 365 com suporte direto à coautoria.

## Pré-requisitos de build

- Um **.NET SDK** em `installer\.tools\dotnet` ou disponível no `PATH`. O
  script prefere automaticamente o SDK portátil quando ele existe; o runtime
  isolado não basta.
- Acesso ao NuGet.org para restaurar `WixToolset.Sdk/4.0.6` e, para o
  distribuidor, `WixToolset.Bal.wixext/4.0.6`.
- O MSI oficial do WinFsp deve permanecer em
  `third-party\winfsp\winfsp.msi` e corresponder ao manifesto fixado.

O projeto fixa o WiX em 4.0.6 para manter os builds reproduzíveis. Os scripts
não instalam ferramentas de build. O SDK portátil, seu cache NuGet e os
arquivos temporários em `.tools` não entram no MSI nem no controle de versão.

## Versão fixada do WinFsp

O distribuidor usa **WinFsp 2.2.26215, 2026 Beta4**, tag
[`v2.2B4`](https://github.com/winfsp/winfsp/releases/tag/v2.2B4). É uma
pré-release escolhida de forma consciente porque essa linha corrige
vulnerabilidades e deadlocks relacionados a operações de escrita e renomeação,
com impacto direto em unidades SharePoint graváveis.

O asset oficial fixado é
[`winfsp-2.2.26215.msi`](https://github.com/winfsp/winfsp/releases/download/v2.2B4/winfsp-2.2.26215.msi),
com SHA-256
`2ECB5C89405488A95BBD8A01875E02C48534FD37BBDFD84488F7590464D65944`.
O teste compara o arquivo local com esse valor antes do build. Uma futura troca
de versão exige nova revisão da release e atualização conjunta de URL, versão,
hash, binário e documentação.

## Validar a estrutura

Na raiz do projeto, execute:

```powershell
.\installer\scripts\Test-InstallerLayout.ps1
```

O teste confere XML, nome público do produto, escopo por máquina, pasta de
instalação, reparo, atalhos comuns, reconexão no logon, ausência de VBS e
CustomActions, upgrade, cadeia do WinFsp e a lista fechada de arquivos
permitidos no pacote.

## Gerar somente o MSI

```powershell
.\installer\scripts\Build-Installer.ps1 -ProductVersion 1.1.5
```

O script prepara o pacote, valida o SHA-256 e a versão do rclone, restaura o
WiX e cria o MSI em `installer\bin\msi`. Esse MSI isolado pressupõe que o
WinFsp já esteja instalado e funcionando no computador de destino.

## Gerar o instalador recomendado

Com o WinFsp fixado presente em `third-party\winfsp\winfsp.msi`, execute:

```powershell
.\installer\scripts\Build-Installer.ps1 `
  -ProductVersion 1.1.5 `
  -IncludeBundle `
  -WinFspMsiPath .\installer\third-party\winfsp\winfsp.msi
```

O `Setup.exe` fica em `installer\bin\bundle`. A cadeia sempre entrega o MSI
oficial ao Windows Installer, que mantém, repara ou atualiza uma instalação
WinFsp 2.x. Isso evita preservar uma versão 2.x antiga apenas porque o serviço
já existe. O build confere o SHA-256 antes de encadear o pacote.

O caminho de atualização suportado pelo fornecedor cobre WinFsp 2.x para 2.x.
Uma instalação legada WinFsp 1.x pode exigir remoção prévia e reinicialização do
Windows antes de executar o instalador do SharePoint Fácil.

## Atualização e publicação

O `UpgradeCode` do MSI e o do distribuidor são fixos. Não os altere depois do
primeiro lançamento. Aumente a versão do produto em cada atualização, por
exemplo de `1.0.1` para `1.0.2`. O `MajorUpgrade` bloqueia versões antigas e
remove a versão anterior.

Antes de distribuir, assine o `.msi` e o `Setup.exe` com o certificado de
assinatura de código da organização. Valide instalação, reparo, atualização,
reconexão após logon e desinstalação em uma VM ou Windows Sandbox limpo. Nunca
inclua certificados, senhas, tokens ou configurações de usuários no pacote.

O publicador previsto é **UTI DA INFORMATICA LTDA**, CNPJ
**04.181.850/0001-94**, site `https://utidainformatica.net/`. O nome exibido
pelo Windows na assinatura será o nome legal validado pela autoridade
certificadora; ele deve coincidir exatamente com os registros oficiais da
empresa. A chave privada deve ficar em token/HSM ou serviço de assinatura em
nuvem e nunca no repositório. A publicação deve usar Authenticode SHA-256 com
timestamp RFC 3161 para que a assinatura continue verificável após a renovação
do certificado.

## Atualizar o rclone

O build lê o `rclone.exe` na raiz do projeto. Ao trocar a versão, valide o
arquivo de origem e atualize no mesmo conjunto de mudanças:

- versão e SHA-256 em `config/payload.manifest.json`;
- versão em `assets/THIRD-PARTY-NOTICES.txt`;
- documentação em `third-party/rclone/README.md`.

`-SkipRcloneHashCheck` serve somente para investigação local e não deve ser
usado em um pacote distribuído.
# Versão 1.1 — reserva por arquivo e coautoria

A unidade permanece gravável. O instalador inclui os comandos “Reservar e abrir”,
“Abrir para coautoria”, “Abrir no SharePoint” e “Concluir edição exclusiva” no submenu
clássico do Explorador. A reserva é explícita por arquivo, com proteção limitada:
edições diretas pela unidade não passam por esse controle. Os documentos abertos
por URL são salvos pelo Office, com a mesma conta usada na conexão.

Antes de desinstalar, conclua as reservas em “Reservas / concluir” ou no SharePoint.
Os registros locais são preservados, e a desinstalação não libera reservas remotas.
Consulte `../DOCUMENTOS-OFFICE.md` para recuperação e roteiro de testes com duas contas.
# Versão 1.1.1 — inicialização sem terminal

Os atalhos do menu Iniciar, da área de trabalho, do logon e os comandos do
Explorador agora chamam `SharePointFacil.exe`, um inicializador gráfico x64.
Ele cria o processo PowerShell com `UseShellExecute=false` e `CreateNoWindow=true`.
O rclone mantém sua inicialização em segundo plano. Abrir manualmente o arquivo
PS1 em um terminal continua sendo um fluxo de diagnóstico com console.

O staging compila `src/Launcher.cs` com o compilador do .NET Framework 4 do
Windows, por meio de `scripts/Build-Launcher.ps1`, e inclui o executável no MSI.
O teste `tests/Test-Launcher.ps1` valida o subsistema gráfico do executável,
o encaminhamento dos argumentos e a ausência de console no processo PowerShell
em sete inicializações reais com um script de teste isolado.

# Versão 1.1.2 — confirmação de checkout e detecção remota

As consultas de documentos solicitam explicitamente o `publicationFacet` do
Microsoft Graph, necessário para confirmar o proprietário do checkout. A montagem
consulta mudanças externas a cada 15 segundos e usa cache de diretório de um minuto
como fallback. O botão `Atualizar` invalida a listagem da biblioteca selecionada
sem descartar alterações locais pendentes.

# Versão 1.1.3 — atualização do Explorador e revisão do backend

Um processo gráfico auxiliar, único por usuário e sem console, sinaliza ao
Explorador as pastas abertas das unidades montadas. Ele trabalha junto da
consulta remota de 15 segundos e encerra quando não existem mais montagens.
O botão `Atualizar` também invalida o VFS e sinaliza a pasta imediatamente.

Os remotes OneDrive usam `upload_cutoff=off`, conforme o padrão recomendado pelo
rclone para OneDrive Business/SharePoint. As opções globais `IgnoreSize` e
`IgnoreChecksum`, próprias de comparação em copy/sync, foram removidas da
montagem; a compatibilidade do Office permanece baseada em cache VFS `full`.
