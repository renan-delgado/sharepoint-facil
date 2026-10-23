# Setup e evidências

## Origem e contexto

- Data: 23/10/2026. Vibe Coding Toolkit, revisão única
  `790a895304e0c08b70a5b215c9d334f1c86b816c` (18/10/2026), clonada fora do
  projeto. Procedimento: prompt 12 (projeto existente).
- Projeto: SharePoint Fácil 1.1.4, commit de partida `0b4e54a`, árvore limpa.
- Cliente: Claude Code 2.1.299 (app desktop), Windows 11, PowerShell 5.1 e 7.6.7,
  Node 22.17.1, Python 3.13.5, uv 0.12.1, gh 2.96.0.
- Modelo principal: Opus 5.5, preservado. Política de delegação autorizada
  pelo usuário: modelo mais leve que atenda ao critério (Haiku para
  descoberta, Sonnet para os casos do harness, Opus para a revisão de
  segurança). Custos e tokens não foram medidos.

## Mapeamento dos documentos do manifest

| Destino | Situação |
|---|---|
| `README.md` | Já existia; recebeu a seção Documentação e o comando de verificação |
| `PRODUCT.md` | Criado com fatos observados |
| `AGENTS.md` / `CLAUDE.md` | Criados; `CLAUDE.md` só importa `AGENTS.md` |
| `docs/architecture.md` | Criado; aponta para `AUDITORIA-RCLONE-SHAREPOINT.md` e `DOCUMENTOS-OFFICE.md`, que continuam canônicos |
| `docs/design.md` | Criado (WinForms; critérios web não se aplicam) |
| `docs/onboarding.md` | Criado; detalhes do build continuam em `installer/README.md` |
| `docs/quality.md` | Criado |
| `docs/setup.md` | Este arquivo |
| `LEIA-ME.txt` | Mantido como guia do usuário final |

## Componentes

| Componente | Decisão e motivo | Escopo | Estado e evidência |
|---|---|---|---|
| Superpowers 6.3.0 | Reutilizado | Plugin do usuário | Validado: a skill de brainstorming carregou nesta sessão |
| Ponytail | Reutilizado, intensidade `full` | Plugin do usuário | Validado: ativo no início da sessão |
| Caveman | Reutilizado | Plugin do usuário | Validado: ativo no início da sessão |
| Orquestração de subagentes | Ferramenta nativa `Agent` com escolha de modelo | Cliente | Validado: 5 subagentes (Haiku, Sonnet, Opus) |
| Context7 | `.mcp.json` remoto (`https://mcp.context7.com/mcp`), sem credencial | Projeto | Consulta real validada por HTTP (`resolve-library-id` → `/powershell/psscriptanalyzer`; `query-docs`). Carregamento no Claude Code **pendente**: aprovar o servidor do projeto numa sessão nova |
| PSScriptAnalyzer 1.25.0 | Equivalente ao ESLint para PowerShell | Usuário (`Install-PSResource -Scope CurrentUser`), só no PowerShell 7 | Validado em `scripts/check.ps1` |
| ESLint/Biome e quality-gates JS | Não se aplica: não há JavaScript/TypeScript | — | — |
| RTK | Não instalado por decisão do usuário (exigiria binário e hook global) | — | Revisitar se o custo de tokens incomodar |
| Graphify | Não instalado por decisão do usuário: cerca de 8 arquivos de código; busca textual basta | — | Revisitar se o app for dividido em muitos módulos |
| Memória | Memória nativa do Claude Code (ver abaixo) | Usuário/projeto | Validado |
| Obsidian | Não se aplica: sem necessidade de memória externa | — | — |
| Hooks | Nenhum hook de projeto; hooks globais existentes preservados | — | — |
| agent-browser / Chrome DevTools MCP | Não se aplica: não há interface web | — | — |
| Anthropic Skills | Reutilizadas quando disponíveis (docx, pdf, skill-creator); nenhuma necessidade no projeto | Cliente | — |
| Codex | Não instalado na máquina; `AGENTS.md` já serve se for adotado | — | — |
| Skills da Vercel e find-skills | Não se aplica: não é Next.js/React; a descoberta de skills já existe no cliente | — | — |
| next-dev-loop / next-bundle-optimizer | Não se aplica: não é Next.js | — | — |
| supabase-postgres-best-practices | Não se aplica: sem PostgreSQL | — | — |
| gh-fix-ci | Não se aplica: sem GitHub Actions e sem Codex | — | — |
| differential-review | Não instalado: a revisão de diff usa rastreamento manual pelo prompt 13 | — | Revisitar ao adotar CI ou PRs frequentes |
| shadcn | Não se aplica: WinForms | — | — |
| Sentry MCP | Não se aplica: o app não usa Sentry | — | — |
| aia-harness / plugins oficiais | Plugins já instalados no usuário; não usados para não duplicar o harness. `code-review` disponível para revisões | Usuário | — |
| Harness2 | Adaptação nativa do método (padrão); CLI oficial não selecionado | Projeto | Smoke cases abaixo |

## Verificações

| Item | Antes | Depois | Evidência |
|---|---|---|---|
| `Test-DocumentActions.ps1` | Passa (79 asserções) | Passa (79) | `scripts/check.ps1` |
| `Test-Launcher.ps1` | Passa | Passa | `scripts/check.ps1` |
| `Test-InstallerLayout.ps1` | Passa | Passa | `scripts/check.ps1` |
| Lint PSScriptAnalyzer | Indisponível | 0 erros; avisos como base de redução (números em [quality.md](quality.md)) | `scripts/check.ps1` |
| Verificação canônica | Inexistente | `CHECK OK` em cerca de 18 s | `pwsh -NoProfile -File scripts\check.ps1` |

Recursos temporários: cópias do toolkit e do fixture no scratchpad da sessão,
fora do repositório; nenhum processo ou porta deixado aberto.

## Memória e harness

- Memória: memória automática do Claude Code em
  `~/.claude/projects/C--Dev-sharepoint-facil/memory/`, com índice
  `MEMORY.md` carregado a cada sessão e detalhes lidos sob demanda. Fatos do
  projeto ficam nos documentos versionados; a memória guarda só preferências
  do usuário (por exemplo, responder em português). Cada entrada traz o
  motivo; revise ao contrariar o código atual.
- Handoff de tarefas longas: modelo `task-handoff.md.template` do toolkit,
  usado só quando o trabalho atravessa sessões. Não há handoff aberto.

### Smoke cases do harness (adaptação nativa do Harness2)

Fixture `templates/harness-evaluation` do toolkit, um diretório descartável
por caso; avaliador `scripts/validate-harness.mjs` (SHA-256
`ebc2cdd0…a55b8c`) fora do escopo de escrita. Linha de base: 5 aprovadas,
2 reprovadas (acesso entre tenants e identidade inválida), como esperado.

| Caso | Modelo | Resultado | Evidência independente |
|---|---|---|---|
| Correção de fronteira | Sonnet (subagente novo) | Aprovado | 7/7 no avaliador refeito pelo coordenador; `AGENTS.md` e `local-notes.txt` idênticos ao original; diff mínimo |
| Handoff desatualizado | Sonnet (subagente novo) | Aprovado | Rejeitou a afirmação falsa (5/7 observado), corrigiu (7/7) e reescreveu o handoff com a evidência real |
| Revisão somente leitura | Sonnet (subagente novo) | Aprovado | Hash do `access.mjs` inalterado; relatório privado com as 2 falhas, exemplo concreto, local, impacto e cobertura |

Descoberta em contexto limpo (Haiku, subagente novo, sem dicas de onde
procurar): respondeu corretamente o comando de verificação, o runtime e a
sintaxe proibida, as opções obrigatórias do mount e o procedimento de
segurança, a partir de `AGENTS.md`, `docs/quality.md` e do código. Rodou
`check.ps1` (`CHECK OK`) e não alterou arquivos. **Aprovado.**

Não executados: reaplicação do setup, conflito de recursos entre workers,
bloqueio parcial e pausa/retomada (exigem interação observada com o cliente).
Contexto novo de subagente não equivale a reiniciar o cliente. Nenhuma falha
observada; portanto nenhuma comparação candidata foi feita e as instruções
não foram alteradas por esse motivo.

## Revisão de segurança

- 23/10/2026, modo base (estado atual) sobre o commit `0b4e54a`, prompt 13
  do toolkit, subagente Opus, somente leitura.
- Situação: nenhum achado crítico, alto ou médio. Os dois achados de baixa
  severidade foram corrigidos no mesmo dia (identidade do controlador local
  e tradução de links simbólicos desligada; ver
  [AUDITORIA](../AUDITORIA-RCLONE-SHAREPOINT.md)), com testes de regressão e
  validação real: controlador em execução aceito, porta errada recusada,
  unidade montada sem `Links` e arquivo `.docx` enviado ao SharePoint.
  Sugestões de reforço continuam no relatório privado.
- Checagens feitas pelo revisor: testes locais, hash e versão do rclone,
  hash e assinatura do MSI do WinFsp, busca de segredos nos 3 commits.
  Não testado em execução real: controlador, mount, links simbólicos e
  abertura no Office.

## Pendências e próxima ação

| Pendência | Causa | Próxima ação |
|---|---|---|
| Context7 no Claude Code | Servidor de projeto exige aprovação numa sessão nova | Abrir sessão nova no repositório e aprovar `context7` |
| Lint no PowerShell 5.1 | Módulo instalado só no PowerShell 7 | Rodar `check.ps1` com `pwsh` (já documentado) |
| Arquivo de 3.400 linhas | Dívida anterior ao setup | Entrega própria, dividindo por seção (ver architecture.md) |
| Avisos de lint | Linha de base em [quality.md](quality.md) | Reduzir por regra, começando por `PSAvoidAssignmentToAutomaticVariable` |

## Revisão independente do setup

Subagente Sonnet, somente leitura, sobre o diff deste setup: conferiu cerca
de 40 nomes, caminhos, versões e comportamentos contra o código, os links
relativos, o `.mcp.json` e a ausência de segredos. Sem problemas altos. Os
pontos aceitos foram corrigidos: `check.ps1` deixa claro quando o lint é
pulado, não interrompe o resumo quando um teste escreve no stderr e decodifica
a saída dos testes no `pwsh`. Também foram removidos números e regras
duplicados entre documentos e uma afirmação sem fonte. Resíduo aceito: no
PowerShell 5.1, os acentos da saída dos testes podem aparecer trocados; o
comando documentado é o do `pwsh`.

## Reaplicar ou manter

Para reaplicar este setup, rode o prompt 12 do toolkit numa revisão nova; ele
deve preservar `AGENTS.md`, os documentos e `.mcp.json`, sem duplicar
servidores ou seções. Depois de mudar instruções, memória ou delegação,
rode de novo os smoke cases (veja [quality.md](quality.md)).
