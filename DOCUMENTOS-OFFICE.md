# Edição de documentos — versão 1.1

A unidade continua aceitando leitura, gravação e cache pelo rclone. A reserva
é explícita e por arquivo. O duplo clique em DOCX, XLSX e PPTX de uma unidade
abre o documento no Office pela URL do SharePoint (coautoria). Não há
interceptação de fechamento ou substituição de arquivos no Explorador.

## Duplo clique

O instalador define o verbo padrão `SharePointFacil.Open` em `Word.Document.12`,
`Excel.Sheet.12` e `PowerPoint.Show.12`. O inicializador lê as letras mapeadas
em `settings.json` sem iniciar o PowerShell:

- arquivo fora das unidades: repassado ao verbo `Open` original do Office;
- arquivo em uma unidade: resolvido no Graph e aberto com `ms-word:ofe|u|<url>`
  (ou Excel/PowerPoint), sem checkout;
- envio pendente, cache não verificável, falha no Graph, sem internet ou Office
  sem suporte à URL: abre a cópia da unidade, como antes, e registra o motivo no log.

Vários arquivos abertos juntos são enfileirados. Formatos antigos (DOC, XLS,
PPT) e com macro continuam abrindo pela unidade. Se o usuário escolheu outro
aplicativo padrão para a extensão, ou um reparo do Office redefinir o verbo
padrão, o duplo clique volta a abrir pela unidade; Reparar no SharePoint Fácil
restaura. A desinstalação remove só o verbo do produto e o valor padrão, e o
Windows volta a usar `Open`.

## Fluxos implementados

| Comando | Comportamento |
|---|---|
| Reservar e abrir | Resolve o item no Graph, verifica cache pendente, registra a intenção local, solicita checkout, confirma o proprietário e abre a URL no Office. |
| Abrir para coautoria | Recusa reservas conhecidas e formatos fora de DOCX/XLSX/PPTX, verifica cache pendente e abre a URL no Office. |
| Concluir edição exclusiva | Exige confirmação de salvamento e fechamento, verifica reserva local/proprietário e solicita check-in. Não força publicação major nem ignora aprovações. |
| Abrir no SharePoint | Abre a webUrl retornada pelo Graph para arquivo ou pasta. |
| Já concluí no site: conferir | Consulta por ID estável e remove somente o registro local quando o servidor informa `published` e nenhum proprietário de checkout. Não faz check-in. |

O rclone continua gerenciando as operações feitas pela unidade. Os documentos
abertos pelos novos comandos são transferidos e salvos pelo Office diretamente
no SharePoint. O aplicativo não consegue verificar o cache offline do Office;
um usuário só deve concluir a reserva depois da confirmação de envio no Office.
O rclone consulta notificações de mudança a cada 15 segundos. Como o `cmount` no
Windows ainda não repassa toda invalidação do VFS ao cache do Explorador, um
observador do SharePoint Fácil sinaliza as pastas abertas a cada ciclo. Uma
alteração externa normalmente aparece em até 30 segundos sem F5. O botão
`Atualizar` invalida a listagem selecionada manualmente e sinaliza o Explorador,
desde que não existam envios locais pendentes.

## Persistência e falhas

`%LOCALAPPDATA%\SharePointFacil\reservations.json` registra IDs de biblioteca,
item e usuário, caminho relativo, data e estado. Não contém tokens. Usa gravação
atômica e a ACL privada do aplicativo. Uma cópia anterior não é recuperada
automaticamente porque pode representar uma reserva já encerrada.

Estados: `CheckoutPending` → `Reserved` → `CheckinPending` → remoção do registro.
O estado de intenção é persistido antes de cada POST. Timeouts e respostas ambíguas
exigem conferência no site; não há repetição automática nem liberação no encerramento.
Se o Office não abrir, a reserva permanece disponível no painel de recuperação.
As operações locais são serializadas por mutex por usuário, inclusive entre a
janela principal e comandos enviados pelo Explorador.

Uma reserva anterior, mesmo da mesma conta, não é adotada automaticamente. Uma
reserva não impede ações de administradores nem garante exclusividade entre
computadores usando a mesma identidade. Gravações diretas pela unidade e renomeações
que substituem o item continuam fora do controle do aplicativo. A verificação de
cache é pontual, e não um bloqueio para futuras gravações do rclone.

## Validação

- Testes isolados: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Test-DocumentActions.ps1 -VerifyUi`.
- Integração rclone/WinFsp local: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File RcloneDriveManager.ps1 -SelfTest`.
- Instalador: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File installer\scripts\Build-Installer.ps1 -IncludeBundle`.

Antes de distribuir para clientes, validar em um tenant de piloto com duas contas
distintas: checkout já existente, abertura no Office instalado, check-in após envio,
coautoria real, biblioteca com checkout obrigatório/aprovação, cancelamento de
checkout por administrador, falta de internet e retomada após reinício. Os testes
isolados simulam o Graph e não comprovam esses comportamentos no Microsoft 365.

O instalador registra o submenu clássico do Explorador e remove apenas suas próprias
chaves na desinstalação. O submenu aparece em arquivos e pastas; o aplicativo recusa
caminhos fora dos mapeamentos. A associação de extensão escolhida pelo usuário
não é alterada; apenas o verbo padrão dos três tipos Office citados acima.

## Referências técnicas

- [Microsoft Graph: checkout](https://learn.microsoft.com/en-us/graph/api/driveitem-checkout?view=graph-rest-1.0)
- [Microsoft Graph: checkin](https://learn.microsoft.com/en-us/graph/api/driveitem-checkin?view=graph-rest-1.0)
- [Microsoft Graph: publicationFacet](https://learn.microsoft.com/en-us/graph/api/resources/publicationfacet?view=graph-rest-1.0)
- [Office URI Schemes](https://learn.microsoft.com/en-us/office/client-developer/office-uri-schemes)
- [rclone: Remote Control API](https://rclone.org/rc/)
