# Preparação local (desenvolvimento)

## Pré-requisitos

- Windows 10/11 x64 com Windows PowerShell 5.1 (o app roda nele).
- PowerShell 7 (`pwsh`) para `scripts/check.ps1` e o lint.
- .NET Framework 4 x64 (`csc.exe`), usado para compilar o inicializador.
- Para gerar instaladores: um .NET SDK em `installer\.tools\dotnet` (portátil,
  preferido) ou no `PATH`, e acesso ao NuGet.org para o WiX 4.0.6. Detalhes
  em [installer/README.md](../installer/README.md).
- Opcional: PSScriptAnalyzer (`Install-PSResource PSScriptAnalyzer -Scope CurrentUser`).

## Primeira execução

1. Baixe `rclone.exe` 1.75.1 (Windows amd64) de
   <https://downloads.rclone.org/v1.75.1/> para a raiz do repositório. O hash
   esperado está em `installer/config/payload.manifest.json`; o app recusa
   outro binário.
2. Instale o WinFsp 2.x (ou o `Setup.exe` do projeto).
3. Rode `powershell.exe -NoProfile -ExecutionPolicy Bypass -File RcloneDriveManager.ps1`.

A conta Microsoft é solicitada pelo navegador na primeira conexão. Nenhuma
credencial fica no repositório; os dados locais ficam em
`%LOCALAPPDATA%\SharePointFacil`.

## Verificar

```powershell
pwsh -NoProfile -File scripts\check.ps1
```

Resultado esperado: `CHECK OK`, com o lint relatando 0 erros. Os testes não
usam rede nem a conta Microsoft. O autoteste com rclone e WinFsp reais
(`RcloneDriveManager.ps1 -SelfTest`) monta uma unidade temporária em memória.

## Agentes

Leia [AGENTS.md](../AGENTS.md); [CLAUDE.md](../CLAUDE.md) importa as mesmas
instruções. Ferramentas e integrações configuradas: [setup.md](setup.md).

## Problemas conhecidos

| Sintoma | Causa verificada | Solução |
|---|---|---|
| Arquivos Office salvos não aparecem no SharePoint; log com `corrupted on transfer` | O SharePoint regrava o arquivo e o tamanho muda | Versão 1.1.4 ou superior (`IgnoreSize`/`IgnoreChecksum`) |
| O Office mostra erro ao abrir pela unidade | URL do visualizador web (`Doc.aspx`) | Versão 1.1.4 ou superior (`webDavUrl`) |
| A reconexão automática não monta | Outra janela do app já está aberta (instância única) | Fechar a janela e abrir de novo |
| Mensagens do build com acentos trocados no PowerShell 5.1 | Script sem BOM | Salvar `.ps1` em UTF-8 com BOM |
