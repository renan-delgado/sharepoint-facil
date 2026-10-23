# Interface e acessibilidade

## Direção

Aplicativo desktop para usuários de escritório, em português do Brasil. A
janela principal é uma ferramenta de configuração; o uso diário acontece no
Explorador de Arquivos e no Office. Critérios visuais de web (breakpoints,
layout responsivo) não se aplicam.

## Sistema existente

- Cores: `$script:Colors` em `RcloneDriveManager.ps1` (Navy, Teal, Canvas,
  Success, Warning, Danger etc.). É a única fonte dos valores.
- Fonte: Segoe UI 9,5 pt (títulos em Segoe UI Semibold); `AutoScaleMode = Dpi`.
- Componentes: WinForms nativos, botões criados por `New-MainButton` e
  `Set-DialogButtonStyle`; ícone em `installer/assets/SharePointFacil.ico`.
- Janela principal: 980×730 px, mínimo 980×650 px.

## Interação

- Ações demoradas mostram uma janela de espera (`New-BusyWindow`) e o estado
  no rodapé; erros usam mensagens em linguagem simples (`Show-FriendlyError`).
- Botões principais têm `AccessibleName`; dicas (`ToolTip`) explicam ações
  destrutivas.
- Integração com o Explorador: item "Abrir no SharePoint" no botão direito e verbo padrão
  "Abrir (SharePoint Fácil)" nos tipos DOCX/XLSX/PPTX.

## Revisão

`tests\Test-DocumentActions.ps1 -VerifyUi` monta a janela fora da tela,
verifica sobreposição de controles no tamanho mínimo e salva
`tests/artifacts/document-actions-ui.png`. Não há verificação automatizada de
contraste nem de navegação por teclado.

## Manutenção

Mudanças visuais alteram `$script:Colors` e os construtores de botão; atualize
este documento quando uma regra mudar.
