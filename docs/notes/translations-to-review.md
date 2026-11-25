# Translations to review

These are the translations an agent wrote for the iPhone accessibility and localization branch
(`feature/iphone-a11y-l10n`). Every other key the branch added reuses a translation the Mac app or
the LineformCore package already had, word for word.

How the list was made: every key added to `LineformiOS/Localizable.xcstrings` against `origin/main`
whose Spanish, French, German, Japanese and Chinese values do not all match the same English key in
`Lineform/Localizable.xcstrings` or the package catalog.

## What to check

- **Native phrasing.** All of these are spoken by VoiceOver, not drawn on screen: an announcement,
  a hint, an action, a rotor name or a value. Read each one aloud. It should sound like the system, short
  and plain, not like a translated sentence.
- **Consistency with the Mac.** "History", "Mark", "Markdown" and "plain text" should use the same
  words as the Mac's menus in that language.
- **Length.** None of them is drawn, so length only matters for listening: shorter is better.
- **Placeholders.** `%@` and `%lld` stay; the numbered forms (`%1$@`, `%2$@`) may move to suit the
  word order. The quotation marks follow each language's convention (Japanese uses 「」).

## The list (20 keys)

| Key (English) | es | fr | de | ja | zh-Hans | Where |
|---|---|---|---|---|---|---|
| `%@ %@` | %1$@ %2$@ | %1$@ %2$@ | %1$@ %2$@ | %1$@%2$@ | %1$@%2$@ | Styling sheet: a slider's spoken name, title then qualifier ("Block Spacing (Read / Preview)"). VoiceOver only. `StylingRows.swift` |
| `Closes the menu and opens History.` | Cierra el menú y abre el historial. | Ferme le menu et ouvre l’historique. | Schließt das Menü und öffnet den Verlauf. | メニューを閉じて履歴を開きます。 | 关闭菜单并打开历史记录。 | Menu sheet: VoiceOver hint on the History section button. `MenuSheet.swift` |
| `Converted to Markdown` | Convertido a Markdown | Converti en Markdown | In Markdown umgewandelt | Markdownに変換しました | 已转换为 Markdown | Menu ▸ Document: VoiceOver announcement after Convert to Markdown. `DocumentSection.swift` |
| `Converted to plain text` | Convertido a texto normal | Converti en texte brut | In reinen Text umgewandelt | プレーンテキストに変換しました | 已转换为纯文本 | Menu ▸ Document: VoiceOver announcement after Convert to Plain Text. `DocumentSection.swift` |
| `Delete “%@”` | Eliminar “%@” | Supprimer « %@ » | „%@“ löschen | 「%@」を削除 | 删除“%@” | AI review: VoiceOver value of a change that only removes text. `AIReviewOverlay.swift` |
| `Formatting options available at the bottom of the screen.` | Opciones de formato disponibles en la parte inferior de la pantalla. | Options de mise en forme disponibles en bas de l’écran. | Formatierungsoptionen unten auf dem Bildschirm verfügbar. | 画面下部でフォーマットオプションを利用できます。 | 屏幕底部提供格式选项。 | Selection row: VoiceOver announcement, once per session, when text is selected. `SelectionRow.swift` |
| `Heading level %lld` | Encabezado de nivel %lld | Titre de niveau %lld | Überschrift, Ebene %lld | 見出しレベル%lld | %lld 级标题 | Menu ▸ Outline: VoiceOver value of a heading row. `OutlineSection.swift` |
| `Hidden` | Oculto | Masqué | Ausgeblendet | 非表示 | 已隐藏 | Menu ▸ Files: VoiceOver detail after a hidden file's name and date. `FolderView.swift` |
| `Hidden, not downloaded` | Oculto, no descargado | Masqué, non téléchargé | Ausgeblendet, nicht heruntergeladen | 非表示、未ダウンロード | 已隐藏，未下载 | Menu ▸ Files: VoiceOver detail, hidden and not downloaded. `FolderView.swift` |
| `History closed` | Historial cerrado | Historique fermé | Verlauf geschlossen | 履歴を閉じました | 已关闭历史记录 | Editor: VoiceOver announcement when History mode ends (not when typing ended it). `LineformiOSTextView+History.swift` |
| `Insert “%@”` | Insertar “%@” | Insérer « %@ » | „%@“ einfügen | 「%@」を挿入 | 插入“%@” | AI review: VoiceOver value of a change that only adds text. `AIReviewOverlay.swift` |
| `Mark task done` | Marcar la tarea como hecha | Marquer la tâche comme faite | Aufgabe als erledigt markieren | タスクを完了にする | 将任务标记为已完成 | Read view: VoiceOver action on an open task with no text. `LineformReadView.swift` |
| `Mark task done: %@` | Marcar la tarea como hecha: %@ | Marquer la tâche comme faite : %@ | Aufgabe als erledigt markieren: %@ | タスクを完了にする: %@ | 将任务标记为已完成：%@ | Read view: VoiceOver action on an open task; %@ is the task's text. `LineformReadView.swift` |
| `Mark task not done` | Marcar la tarea como pendiente | Marquer la tâche comme non faite | Aufgabe als offen markieren | タスクを未完了にする | 将任务标记为未完成 | Read view: VoiceOver action on a done task with no text. `LineformReadView.swift` |
| `Mark task not done: %@` | Marcar la tarea como pendiente: %@ | Marquer la tâche comme non faite : %@ | Aufgabe als offen markieren: %@ | タスクを未完了にする: %@ | 将任务标记为未完成：%@ | Read view: VoiceOver action on a done task; %@ is the task's text. `LineformReadView.swift` |
| `Marked sentences` | Oraciones marcadas | Phrases marquées | Markierte Sätze | マークされた文 | 标记的句子 | Editor: VoiceOver rotor name while Mark's sentences show. `LineformiOSTextView.swift` |
| `Not connected` | No conectado | Non connecté | Nicht verbunden | 未接続 | 未连接 | Menu ▸ Settings: VoiceOver value of Connect Your AI… when no AI is connected. `SettingsSection.swift` |
| `Not downloaded` | No descargado | Non téléchargé | Nicht heruntergeladen | 未ダウンロード | 未下载 | Menu ▸ Files: VoiceOver detail for an iCloud file with no local copy. `FolderView.swift` |
| `Passages` | Pasajes | Passages | Passagen | 箇所 | 片段 | Editor: VoiceOver rotor name in History mode. `LineformiOSTextView.swift` |
| `Replace “%@” with “%@”` | Reemplazar “%1$@” por “%2$@” | Remplacer « %1$@ » par « %2$@ » | „%1$@“ durch „%2$@“ ersetzen | 「%1$@」を「%2$@」に置き換え | 将“%1$@”替换为“%2$@” | AI review: VoiceOver value of a change that replaces text. `AIReviewOverlay.swift` |

## Not in the list

The same branch also marked 2 iPhone entries (`%@, version %lld of %lld` and
`%@, original, version %lld of %lld`, English only) and 110 package entries `translated` where they
were `new`. Their text did not change, so they are not new translations, but nobody had marked them
reviewed before.

## Added 2026-11-24 (review4-mockups: the build matched to the approved mockups)

Written for the iPhone, not reused from the Mac (the Mac has no such strings).

| Key (English) | es | fr | de | ja | zh-Hans | Where |
|---|---|---|---|---|---|---|
| `Export PDF…` | Exportar PDF… | Exporter en PDF… | PDF exportieren … | PDFを書き出す… | 导出 PDF… | Menu ▸ Export & Print. `PhoneExportFormat.swift` |
| `Export HTML…` | Exportar HTML… | Exporter en HTML… | HTML exportieren … | HTMLを書き出す… | 导出 HTML… | Menu ▸ Export & Print. `PhoneExportFormat.swift` |
| `Export Markdown…` | Exportar Markdown… | Exporter en Markdown… | Markdown exportieren … | Markdownを書き出す… | 导出 Markdown… | Menu ▸ Export & Print. `PhoneExportFormat.swift` |
| `Reset to Theme` | Restablecer el tema | Rétablir le thème | Auf Thema zurücksetzen | テーマに戻す | 恢复主题设置 | Themes sheet's reset button. `StylingSheet.swift` |
| `Close Themes` | Cerrar Temas | Fermer Thèmes | Themen schließen | テーマを閉じる | 关闭主题 | Themes sheet: VoiceOver name of the grabber. `StylingSheet.swift` |
| `Version %lld/%lld` | Versión %lld/%lld | Version %lld/%lld | Version %lld/%lld | バージョン %lld/%lld | 版本 %lld/%lld | History mode's bar. `HistoryCard.swift` |
| `Earlier version` | Versión anterior | Version précédente | Frühere Version | 前のバージョン | 较早的版本 | History bar: VoiceOver name of ‹. `HistoryCard.swift` |
| `Later version` | Versión posterior | Version suivante | Spätere Version | 次のバージョン | 较新的版本 | History bar: VoiceOver name of ›. `HistoryCard.swift` |
| `Sends the whole document to your AI.` | Envía todo el documento a tu IA. | Envoie tout le document à votre IA. | Sendet das ganze Dokument an deine KI. | 書類全体をあなたのAIに送信します。 | 将整篇文稿发送给你的 AI。 | Menu ▸ Connect Your AI ▸ Ask AI…'s note. `ConnectAISection.swift` |
| `Math` (iPhone catalog; the package's own translation) | Fórmulas | Formules | Formeln | 数式 | 数学公式 | Menu ▸ Markdown Basics row name. `BasicsSection.swift` |
| Table row (package): `…Colons align. Insert from the format row.` | …Inserta desde la barra de formato. | …Insérez via la barre de format. | …Einfügen: Formatleiste. | …挿入はフォーマットバーから。 | …在格式栏中插入。 | Markdown Basics, Table row (VoiceOver label). `MarkdownReference.swift`, iOS branch |
| `This conversation ends when you open another document.` (package) | Esta conversación termina cuando abres otro documento. | Cette conversation prend fin quand vous ouvrez un autre document. | Diese Unterhaltung endet, wenn du ein anderes Dokument öffnest. | この会話は別の書類を開くと終了します。 | 打开其他文稿时，此对话即结束。 | AI sheet's start note, iPhone only. `AIConversationPresentation.swift` |
