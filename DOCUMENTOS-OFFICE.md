# Documentos Office e Explorador

A unidade aceita leitura, gravação e cache pelo rclone. Para Word, Excel e
PowerPoint, o duplo clique abre o documento no Office pela URL do SharePoint,
com coautoria e salvamento automático. Checkout e check-in, quando a biblioteca
exigir, são feitos pelo próprio Office (Arquivo › Informações) ou pelo site.

## Duplo clique

O instalador define o verbo padrão `SharePointFacil.Open` em `Word.Document.12`,
`Excel.Sheet.12` e `PowerPoint.Show.12`. O inicializador lê as letras mapeadas
em `settings.json` sem iniciar o PowerShell:

- arquivo fora das unidades: repassado ao verbo `Open` original do Office;
- arquivo em uma unidade: resolvido no Graph e aberto com `ms-word:ofe|u|<url>`
  (ou Excel/PowerPoint), usando o `webDavUrl` do item;
- envio pendente, cache não verificável, falha no Graph, sem internet ou Office
  sem suporte à URL: abre a cópia da unidade, como antes, e registra o motivo no log.

Vários arquivos abertos juntos são enfileirados. Formatos antigos (DOC, XLS,
PPT) e com macro continuam abrindo pela unidade. Se o usuário escolheu outro
aplicativo padrão para a extensão, ou um reparo do Office redefinir o verbo
padrão, o duplo clique volta a abrir pela unidade; Reparar no SharePoint Fácil
restaura. A desinstalação remove só o verbo do produto e o valor padrão, e o
Windows volta a usar `Open`.

## Abrir no SharePoint

O item "Abrir no SharePoint" do botão direito (no Windows 11, em "Mostrar mais
opções") abre no navegador a página do arquivo ou da pasta, para compartilhar,
ver versões ou ajustar permissões. Ele usa o `webUrl` retornado pelo Graph,
validado contra o host da biblioteca. Caminhos fora das unidades do produto são
recusados.

## Alterações externas

O rclone consulta notificações de mudança a cada 15 segundos. Como o `cmount`
no Windows ainda não repassa toda invalidação do VFS ao cache do Explorador, um
observador do SharePoint Fácil sinaliza as pastas abertas a cada ciclo. Uma
alteração externa normalmente aparece em até 30 segundos sem F5. O botão
`Atualizar` invalida a listagem selecionada manualmente.

## Histórico

Até a versão 1.1.5 o aplicativo tinha comandos próprios de reserva (checkout),
coautoria e check-in, com registro em `reservations.json`. Foram removidos na
1.1.6: o duplo clique já abre pelo SharePoint e o Office faz checkout e check-in
nativamente. Um `reservations.json` antigo é ignorado; reservas abertas são
concluídas pelo Office ou pelo site.

## Validação

- Testes isolados: `pwsh -NoProfile -File scripts\check.ps1 -VerifyUi`.
- Integração rclone/WinFsp local: `RcloneDriveManager.ps1 -SelfTest`.
- Comportamento real (abertura no Office, coautoria, biblioteca com checkout
  obrigatório) exige uma biblioteca de teste; os testes simulam o Graph.

## Referências técnicas

- [Office URI Schemes](https://learn.microsoft.com/en-us/office/client-developer/office-uri-schemes)
- [rclone: Remote Control API](https://rclone.org/rc/)
