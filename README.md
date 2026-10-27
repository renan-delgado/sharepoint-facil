# SharePoint Fácil

Conecta bibliotecas de documentos do SharePoint Online ao Explorador de Arquivos
do Windows como letras de unidade (por exemplo, `S:`), com acesso sob demanda:
as pastas são listadas quando abertas e os arquivos baixados quando usados, sem
sincronizar a biblioteca inteira.

## Recursos

- Seleção de sites e bibliotecas acessíveis pela conta Microsoft 365, com
  autenticação delegada (cada usuário usa as próprias permissões).
- Letra, nome e reconexão no logon por biblioteca.
- Opcional: escolher uma subpasta na árvore de pastas da biblioteca para
  mapear, sincronizar ou criar o atalho só dela.
- Opcional: sincronizar qualquer biblioteca da lista pelo próprio OneDrive,
  como o botão Sincronizar do SharePoint, ou adicioná-la como atalho em Meus
  arquivos do OneDrive, como no Teams, sem abrir site por site.
- Cache local com limite de tamanho; envios em segundo plano com nova tentativa.
- Atualização automática de alterações feitas por outros usuários, pelo Teams ou
  pelo site.
- Duplo clique em DOCX, XLSX e PPTX de uma unidade abre o documento no Office
  diretamente do SharePoint (coautoria e salvamento automático). Se não for
  possível, abre a cópia da unidade.
- "Abrir no SharePoint" no botão direito do Explorador: abre o arquivo ou a
  pasta no navegador.
- Instalador MSI por máquina e instalador completo que inclui o WinFsp.

## Requisitos

- Windows 10 ou 11 de 64 bits.
- Conta Microsoft 365 com acesso a bibliotecas do SharePoint Online.
- Microsoft Office desktop, para a abertura pelo SharePoint com coautoria.

## Instalação

**[⬇ Baixar o instalador para Windows (64 bits)](https://github.com/renan-delgado/sharepoint-facil/releases/latest/download/SharePointFacilSetup-x64.exe)**

Execute o instalador baixado. Ele instala ou atualiza o WinFsp e depois o
aplicativo; uma versão anterior é atualizada sem perder as unidades
configuradas. Abra **SharePoint Fácil** pelo menu Iniciar e clique em
**Conectar biblioteca**.

O instalador ainda não tem assinatura digital, então o Windows SmartScreen pode
exibir um aviso: clique em **Mais informações** e em **Executar assim mesmo**.
Versões anteriores e o MSI para implantação por administradores estão em
[Releases](https://github.com/renan-delgado/sharepoint-facil/releases).

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
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File installer\scripts\Build-Installer.ps1 -IncludeBundle
   ```

Detalhes em [`installer/README.md`](installer/README.md).

## Testes

```powershell
pwsh -NoProfile -File scripts\check.ps1
```

Roda o lint (PSScriptAnalyzer, quando instalado) e os três conjuntos de
testes. Detalhes em [`docs/quality.md`](docs/quality.md).

Os testes simulam o Microsoft Graph e não substituem a validação em um tenant
real. Veja [`DOCUMENTOS-OFFICE.md`](DOCUMENTOS-OFFICE.md) e
[`AUDITORIA-RCLONE-SHAREPOINT.md`](AUDITORIA-RCLONE-SHAREPOINT.md) para o
comportamento esperado e as limitações conhecidas.

## Documentação

- [Produto e escopo](PRODUCT.md)
- [Preparação local](docs/onboarding.md)
- [Código e arquitetura](docs/architecture.md)
- [Interface](docs/design.md)
- [Qualidade e verificações](docs/quality.md)
- [Instruções para agentes de IA](AGENTS.md)
- [Setup e evidências](docs/setup.md)
- [Edição de documentos Office](DOCUMENTOS-OFFICE.md) e
  [auditoria do backend rclone](AUDITORIA-RCLONE-SHAREPOINT.md)

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
