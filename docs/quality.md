# Qualidade

## Comandos

| Comando | O que prova |
|---|---|
| `pwsh -NoProfile -File scripts\check.ps1` | Verificação canônica: lint sem erros + os 3 testes abaixo |
| `... scripts\check.ps1 -VerifyUi` | Também desenha a janela e verifica sobreposição no tamanho mínimo |
| `tests\Test-DocumentActions.ps1` | Duplo clique (`Auto`), "Abrir no SharePoint", URLs confiáveis, cache pendente, link do OneDrive, identidade do controlador, opções do mount. Graph simulado |
| `tests\Test-Launcher.ps1` | Inicializador compila como GUI x64, não abre console, preserva argumentos, recusa comandos arbitrários e roteia o duplo clique |
| `installer\scripts\Test-InstallerLayout.ps1` | Layout estático do WiX: componentes, verbos, atalhos, payload aprovado |
| `RcloneDriveManager.ps1 -SelfTest` | rclone e WinFsp reais montando um remote em memória |

Rode os testes isolados com `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <arquivo>`.
O `check.ps1` usa o Windows PowerShell 5.1 para os testes, porque é o runtime
do app; o lint só roda onde o PSScriptAnalyzer estiver instalado e, sem ele,
aparece como `SKIPPED`.

## Regras

- **Lint (PSScriptAnalyzer 1.25.0, regras padrão):** erros reprovam a
  verificação; avisos são relatados para redução gradual. Linha de base em
  23/10/2026: 0 erros, 143 avisos, 57 informativos. Avisos mais frequentes:
  `PSAvoidAssignmentToAutomaticVariable` (49, uso de `$profile`/`$matches`
  como variável local), `PSAvoidUsingEmptyCatchBlock` (26),
  `PSUseShouldProcessForStateChangingFunctions` (22). Não suprima regras em
  massa; reduza por regra, com teste.
- Scripts `.ps1` com caracteres não ASCII precisam de UTF-8 com BOM (o
  PowerShell 5.1 lê sem BOM como ANSI).
- Tamanho de arquivo: referência de 350 linhas. `RcloneDriveManager.ps1`
  está acima (ver Dívida em [architecture.md](architecture.md)); arquivos
  novos devem respeitar o limite.
- Entradas externas validadas na fronteira: caminhos (`Get-DocumentTarget`),
  argumentos do inicializador (`Launcher.CreateStartInfo`), URLs do Graph
  (`Get-TrustedDocumentUrl`), configurações (`ConvertTo-SafeProfile`).

## Estratégia de testes

Os testes carregam as funções do script pelo AST, substituem Graph, rclone e
Office por simulações, e verificam decisões e falhas, como cache sujo, envio
pendente, URL não confiável e controlador local falso. Eles **não** provam o
comportamento no Microsoft 365. Mudanças em envio, Office ou instalador
exigem validação numa biblioteca real, registrada em [setup.md](setup.md).
Não há suíte E2E nem medição de cobertura.

## Revisão depois de implementar ou corrigir

Escolha o escopo pelo risco e pelo diff real. Para mudança não trivial, use
revisão independente (por exemplo, `/code-review` do plugin oficial). Revise
o código alterado e quem o chama, os contratos e os testes. Termine quando
os achados relevantes estiverem resolvidos ou justificados, as checagens
afetadas passarem e os riscos residuais estiverem registrados. Rodadas extras
só com evidência nova ou pedido explícito.

## Revisão de segurança

- Procedimento: prompt 13 do Vibe Coding Toolkit (revisão `790a895`),
  [`docs/prompts/13-security-review.md`](https://github.com/soumatheusgomes/vibe-coding-toolkit/blob/790a895304e0c08b70a5b215c9d334f1c86b816c/docs/prompts/13-security-review.md),
  seção "Prompt". Invocação: peça ao agente para ler esse arquivo e executar
  a seção Prompt neste repositório, em modo base (estado atual) ou diff
  (`<base>..<head>`).
- Somente leitura por padrão; relatório privado **fora** do repositório (por
  exemplo `%LOCALAPPDATA%\security-reviews\`). Achados sensíveis não entram
  em documentação pública nem em issues.
- O `differential-review` da Trail of Bits não está instalado; a revisão de
  diff usa rastreamento manual, como previsto no prompt.
- Revisões feitas: ver [setup.md](setup.md) (apenas data, escopo e situação).

## Melhoria do harness

- Modo: adaptação nativa do método Harness2 (não executa o framework
  Harness2). Procedimento: prompt 15 do toolkit, mesma revisão,
  [`docs/prompts/15-harness-improvement.md`](https://github.com/soumatheusgomes/vibe-coding-toolkit/blob/790a895304e0c08b70a5b215c9d334f1c86b816c/docs/prompts/15-harness-improvement.md),
  e casos de [`docs/07-harness-evaluation.md`](https://github.com/soumatheusgomes/vibe-coding-toolkit/blob/790a895304e0c08b70a5b215c9d334f1c86b816c/docs/07-harness-evaluation.md).
- Rode os casos curtos (correção de fronteira, handoff desatualizado,
  revisão somente leitura) em cópias descartáveis do fixture do toolkit
  depois de mudar `AGENTS.md`, memória, skills ou delegação.
- Uma falha observada justifica uma comparação candidata. Sem falha, não
  altere instruções que funcionam. Resultados em [setup.md](setup.md).

## Dependências e entrega

- Binários de terceiros só entram com versão e SHA-256 conferidos pelo build
  (`installer/config/*.manifest.json`).
- Não há gerenciador de pacotes nem auditoria automatizada de dependências.
  Acompanhe manualmente os avisos de segurança do rclone e do WinFsp ao
  atualizar.
- As checagens são comandos explícitos; não há hooks de Git nem bloqueios de
  branch.
