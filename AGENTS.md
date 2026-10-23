# SharePoint Fácil — instruções para agentes

Aplicativo Windows que monta bibliotecas do SharePoint Online como letras de
unidade usando rclone (VFS + Microsoft Graph) e WinFsp. Escopo em
[PRODUCT.md](PRODUCT.md); mapa do código em
[docs/architecture.md](docs/architecture.md); evidências do setup em
[docs/setup.md](docs/setup.md).

## Stack

- `RcloneDriveManager.ps1`: aplicativo inteiro (Windows PowerShell 5.1,
  WinForms). Precisa de UTF-8 **com BOM** por causa dos acentos.
- `installer/src/Launcher.cs`: inicializador GUI x64 (.NET Framework 4,
  compilado com `csc.exe`); `Product.wxs`/`Bundle.wxs`: WiX 4.0.6.
- Binários de terceiros fixados por SHA-256: `rclone.exe` 1.75.1 (raiz,
  ignorado pelo Git) e WinFsp 2.2.26215 (`installer/third-party/winfsp`).

## Comandos

- Verificação completa: `pwsh -NoProfile -File scripts\check.ps1`
  (lint PSScriptAnalyzer + 3 testes; `-VerifyUi` também desenha a janela).
- Testes isolados: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-DocumentActions.ps1`,
  `tests\Test-Launcher.ps1`, `installer\scripts\Test-InstallerLayout.ps1`.
- Instalador: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File installer\scripts\Build-Installer.ps1 -IncludeBundle`.
- Autoteste com rclone/WinFsp reais: `RcloneDriveManager.ps1 -SelfTest`.
- Não há build separado do app nem CI.

## Regras do projeto

- O app roda no Windows PowerShell 5.1: não use sintaxe só do PowerShell 7
  (`??`, `?.`, ternário, `&&`).
- Nunca registre tokens, senhas ou cabeçalhos de autorização; use
  `Write-AppLog`, que já redige segredos.
- Mudanças no mount (`New-MountRequest`) exigem conferir a seção
  "Configuração adotada" de [AUDITORIA-RCLONE-SHAREPOINT.md](AUDITORIA-RCLONE-SHAREPOINT.md).
  `IgnoreSize`/`IgnoreChecksum` são obrigatórios: sem eles, salvamentos Office
  nunca chegam ao SharePoint.
- Fluxos de documento e duplo clique: [DOCUMENTOS-OFFICE.md](DOCUMENTOS-OFFICE.md).
  O duplo clique sempre precisa abrir o arquivo (fallback para a unidade).
- Não chame `/me` no Graph: o token do rclone não tem `User.Read` (403).
  Use as claims do token (`Get-TokenAccountName`).
- Testes simulam o Graph. Mudança de comportamento real (envio, Office,
  instalador) exige validação numa biblioteca real e registro da evidência.
- Mudar versão: `AppVersion` no script, `Launcher.cs`, os dois `.wixproj` e
  `Build-Installer.ps1`.

## Acordos de trabalho

- Leia as instruções e o código relevante antes de editar. Separe fato
  observado, suposição, decisão e evidência.
- Defina o critério de aceite e o comando de verificação antes de
  implementar. Correção de bug: reproduza primeiro e deixe um teste de
  regressão quando for viável.
- Menor mudança completa; reutilize padrões e funções existentes. Não
  enfraqueça validação, testes ou regras para fazer uma checagem passar.
- Atualize o documento responsável junto com a mudança de comportamento,
  comando ou configuração.
- Publicar, enviar mensagens, gerar custo ou ações destrutivas exigem
  autorização específica. Instalar uma ferramenta não autoriza usá-la.
- Trabalho que atravessa sessões: mantenha um handoff curto (objetivo,
  estado verificado, evidência, próxima ação). Ao retomar, confira arquivos,
  Git e processos reais antes de confiar no handoff.
- Bloqueio parcial afeta só o que depende dele; conclua o resto que for
  seguro e autorizado. Não apresente pendência como resultado.

## Ferramentas

- Superpowers (processo proporcional), Ponytail `full` (menor solução
  completa) e Caveman (conversa concisa; código, docs e commits em texto
  normal) são plugins do Claude Code já instalados.
- Context7 (`.mcp.json`): documentação atual de bibliotecas. Resolva o ID e
  consulte um conceito por vez; nunca envie código privado ou segredos.
- Revisão de segurança e melhoria do harness: procedimentos em
  [docs/quality.md](docs/quality.md).
- Demais ferramentas e decisões de adoção: [docs/setup.md](docs/setup.md).

## Delegação e revisão

- Delegue só quando isolamento de contexto, especialização ou paralelismo
  independente compensarem; para tarefas simples, execute direto.
- Modelo mais leve para inventário, buscas e mudanças mecânicas
  verificáveis; mais capacidade para segurança, dados, concorrência e
  diagnóstico ambíguo. Preserve o modelo principal e a autenticação.
- Cada tarefa delegada recebe objetivo, contexto mínimo, arquivos
  permitidos, critério de aceite e checagens. Um escritor por arquivo;
  revisores são somente leitura. O coordenador confere diff e checagens
  antes de aceitar o resultado.
- Revisão proporcional ao risco do diff real; termine quando os achados
  relevantes estiverem resolvidos ou justificados e as checagens passarem.

## Git

- Sem hooks de commit/push, bloqueios de branch ou exigência de worktree.
- Nunca versione `rclone.exe`, MSI/EXE, `*.msixbundle` nem documentação do
  rclone (veja `.gitignore`).
