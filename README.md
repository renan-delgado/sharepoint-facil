# SharePoint Fácil

Conecta bibliotecas de documentos do SharePoint Online ao Explorador de Arquivos
do Windows como letras de unidade (por exemplo, `S:`), com acesso sob demanda:
as pastas são listadas quando abertas e os arquivos baixados quando usados, sem
sincronizar a biblioteca inteira.

## Recursos

- Seleção de sites e bibliotecas acessíveis pela conta Microsoft 365, com
  autenticação delegada (cada usuário usa as próprias permissões).
- Letra, nome e reconexão no logon por biblioteca.
- Cache local com limite de tamanho; envios em segundo plano com nova tentativa.
- Atualização automática de alterações feitas por outros usuários, pelo Teams ou
  pelo site.
- Duplo clique em DOCX, XLSX e PPTX de uma unidade abre o documento no Office
  diretamente do SharePoint (coautoria e salvamento automático). Se não for
  possível, abre a cópia da unidade.
- Menu de contexto no Explorador: reservar (checkout) e abrir, abrir para
  coautoria, abrir no SharePoint e concluir edição exclusiva (check-in).
- Instalador MSI por máquina e instalador completo que inclui o WinFsp.

## Requisitos

- Windows 10 ou 11 de 64 bits.
- Conta Microsoft 365 com acesso a bibliotecas do SharePoint Online.
- Microsoft Office desktop, para a abertura pelo SharePoint com coautoria.

## Instalação

Baixe `SharePointFacilSetup-<versão>-x64.exe` na página de releases e execute.
O instalador instala ou atualiza o WinFsp e depois o aplicativo. Abra
**SharePoint Fácil** pelo menu Iniciar e clique em **Conectar biblioteca**.

## Compilar

Os binários de terceiros não ficam no repositório. São entradas de build com
versão e SHA-256 fixados:

1. Baixe o rclone 1.75.1 para Windows x64 em
   <https://downloads.rclone.org/v1.75.1/> e
   coloque `rclone.exe` na raiz do repositório. O hash esperado está em
   [`installer/config/payload.manifest.json`](installer/config/payload.manifest.json).
2. Para o instalador completo, baixe o MSI do WinFsp indicado em
   [`installer/config/winfsp.manifest.json`](installer/config/winfsp.manifest.json)
   para `installer/third-party/winfsp/winfsp.msi`.
3. Gere os instaladores:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File installer\scripts\Build-Installer.ps1 -IncludeBundle
   ```

Detalhes em [`installer/README.md`](installer/README.md).

## Testes

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-DocumentActions.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Launcher.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File installer\scripts\Test-InstallerLayout.ps1
```

Os testes simulam o Microsoft Graph e não substituem a validação em um tenant
real. Veja [`DOCUMENTOS-OFFICE.md`](DOCUMENTOS-OFFICE.md) e
[`AUDITORIA-RCLONE-SHAREPOINT.md`](AUDITORIA-RCLONE-SHAREPOINT.md) para o
comportamento esperado e as limitações conhecidas.

## Créditos

O SharePoint Fácil é uma interface sobre dois projetos de código aberto:

- **[rclone](https://rclone.org)** — acesso ao SharePoint pelo Microsoft Graph,
  cache VFS e montagem. Copyright (C) Nick Craig-Wood. Licença MIT. O
  `rclone.exe` oficial é incluído no instalador sem modificações.
- **WinFsp - Windows File System Proxy, Copyright (C) Bill Zissimopoulos** —
  <https://github.com/winfsp/winfsp>. Sistema de arquivos em modo usuário que
  permite a letra de unidade. Licença GPLv3 com exceção FLOSS. O instalador
  oficial do WinFsp é redistribuído sem modificações, conforme essa exceção.

Os avisos e licenças completos estão em
[`installer/assets/THIRD-PARTY-NOTICES.txt`](installer/assets/THIRD-PARTY-NOTICES.txt),
também instalado junto com o aplicativo.

Microsoft, SharePoint, OneDrive e Office são marcas da Microsoft Corporation.
Este projeto não é afiliado nem endossado pela Microsoft, pelo projeto rclone
ou pelo projeto WinFsp.

## Licença

[MIT](LICENSE) © 2026 UTI DA INFORMATICA LTDA
