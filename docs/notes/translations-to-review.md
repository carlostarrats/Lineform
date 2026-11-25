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

## Added 2026-11-24 (review5-prompt-words: the AI prompt words in six languages)

Written for the AI drawer (Mac) and sheet (iPhone); none reused, because no existing key had this
text. Package catalog, `AIPromptLexicon.swift`. Two things to check:

- **The options card.** Each word's question (the card's heading) and its chips. Chips are short,
  lower case where the language allows, and each must read as a choice the writer can tick. The
  model never sees these: it gets the English direction behind each chip.
- **The forms.** The words and phrases that get a dotted underline while the writer types. Are they
  what a native writer would type when asking for that change? Is any of them an everyday word that
  would be underlined in an unrelated sentence (in its own language, or in English)? Japanese and
  Chinese forms match inside longer words, so also flag a form that sits inside a common unrelated
  word (those get a "blocker" entry, like 流れ星 or 扩展名).

### The options card

| Key (English) | es | fr | de | ja | zh-Hans |
|---|---|---|---|---|---|
| `Professional how?` | ¿Más profesional en qué sentido? | En quoi plus professionnel ? | Inwiefern professioneller? | どのようにプロらしく？ | 怎样更专业？ |
| `Formal how?` | ¿Más formal en qué sentido? | En quoi plus formel ? | Inwiefern förmlicher? | どのようにフォーマルに？ | 怎样更正式？ |
| `Casual how?` | ¿Más informal en qué sentido? | En quoi plus décontracté ? | Inwiefern lockerer? | どのようにカジュアルに？ | 怎样更随意？ |
| `Friendlier how?` | ¿Más cercano en qué sentido? | En quoi plus chaleureux ? | Inwiefern freundlicher? | どのように親しみやすく？ | 怎样更友好？ |
| `Polite how?` | ¿Más cortés en qué sentido? | En quoi plus poli ? | Inwiefern höflicher? | どのように丁寧に？ | 怎样更礼貌？ |
| `Softer how?` | ¿Más suave en qué sentido? | En quoi plus doux ? | Inwiefern sanfter? | どのように柔らかく？ | 怎样更柔和？ |
| `Diplomatic how?` | ¿Más diplomático en qué sentido? | En quoi plus diplomate ? | Inwiefern diplomatischer? | どのように角を立てずに？ | 怎样更得体？ |
| `Direct how?` | ¿Más directo en qué sentido? | En quoi plus direct ? | Inwiefern direkter? | どのように率直に？ | 怎样更直接？ |
| `Confident how?` | ¿Más seguro en qué sentido? | En quoi plus assuré ? | Inwiefern selbstbewusster? | どのように自信を持って？ | 怎样更自信？ |
| `More natural how?` | ¿Más natural en qué sentido? | En quoi plus naturel ? | Inwiefern natürlicher? | どのように自然に？ | 怎样更自然？ |
| `Neutral how?` | ¿Más neutral en qué sentido? | En quoi plus neutre ? | Inwiefern neutraler? | どのように中立的に？ | 怎样更中立？ |
| `Shorter how?` | ¿Más corto en qué sentido? | En quoi plus court ? | Inwiefern kürzer? | どのように短く？ | 怎样更短？ |
| `Concise how?` | ¿Más conciso en qué sentido? | En quoi plus concis ? | Inwiefern prägnanter? | どのように簡潔に？ | 怎样更简洁？ |
| `Longer how?` | ¿Más largo en qué sentido? | En quoi plus long ? | Inwiefern länger? | どのように長く？ | 怎样更长？ |
| `Clearer how?` | ¿Más claro en qué sentido? | En quoi plus clair ? | Inwiefern klarer? | どのように分かりやすく？ | 怎样更清楚？ |
| `Simpler how?` | ¿Más sencillo en qué sentido? | En quoi plus simple ? | Inwiefern einfacher? | どのように簡単に？ | 怎样更简单？ |
| `Less jargon how?` | ¿Menos jerga en qué sentido? | Moins de jargon, comment ? | Weniger Fachjargon – wie? | 専門用語をどう減らす？ | 怎样减少术语？ |
| `What makes it flow?` | ¿Qué lo hará más fluido? | Qu’est-ce qui rendra le texte fluide ? | Was macht es flüssiger? | 流れを良くするには？ | 怎样更流畅？ |
| `Specific how?` | ¿Más concreto en qué sentido? | En quoi plus précis ? | Inwiefern konkreter? | どのように具体的に？ | 怎样更具体？ |
| `Structured how?` | ¿Más estructurado en qué sentido? | En quoi plus structuré ? | Inwiefern strukturierter? | どのように構成を整える？ | 怎样更有条理？ |
| `Punchier how?` | ¿Más contundente en qué sentido? | En quoi plus percutant ? | Inwiefern knackiger? | どのように力強く？ | 怎样更有力？ |
| `Engaging how?` | ¿Más atractivo en qué sentido? | En quoi plus captivant ? | Inwiefern fesselnder? | どのように魅力的に？ | 怎样更吸引人？ |
| `Enthusiastic how?` | ¿Más entusiasta en qué sentido? | En quoi plus enthousiaste ? | Inwiefern begeisterter? | どのように熱意を込めて？ | 怎样更有热情？ |
| `Persuasive how?` | ¿Más persuasivo en qué sentido? | En quoi plus convaincant ? | Inwiefern überzeugender? | どのように説得力を高める？ | 怎样更有说服力？ |
| `Creative how?` | ¿Más creativo en qué sentido? | En quoi plus créatif ? | Inwiefern kreativer? | どのように創造的に？ | 怎样更有创意？ |
| `Playful how?` | ¿Más divertido en qué sentido? | En quoi plus ludique ? | Inwiefern verspielter? | どのように遊び心を加える？ | 怎样更俏皮？ |
| `Better how?` | ¿Mejor en qué sentido? | Mieux en quoi ? | Inwiefern besser? | どのように良くする？ | 怎样更好？ |
| `Cleaner how?` | ¿Más limpio en qué sentido? | En quoi plus propre ? | Inwiefern sauberer? | どのように整える？ | 怎样更整洁？ |
| `Academic how?` | ¿Más académico en qué sentido? | En quoi plus académique ? | Inwiefern akademischer? | どのように学術的に？ | 怎样更学术？ |
| `More human how?` | ¿Más humano en qué sentido? | En quoi plus humain ? | Inwiefern menschlicher? | どのように人間らしく？ | 怎样更像人写的？ |
| `Beginners how?` | ¿Para principiantes en qué sentido? | Pour débutants, comment ? | Für Einsteiger – wie? | 初心者向けにどうする？ | 怎样照顾初学者？ |
| `Experts how?` | ¿Para expertos en qué sentido? | Pour experts, comment ? | Für Fachleute – wie? | 専門家向けにどうする？ | 怎样面向专家？ |
| `What should they see first?` | ¿Qué deben ver primero? | Que doivent-ils voir en premier ? | Was sollen sie zuerst sehen? | 最初に何を見せる？ | 先让他们看到什么？ |
| `no slang or emoji` | sin jerga ni emojis | ni argot ni emoji | kein Slang, keine Emojis | 俗語や絵文字なし | 不用俚语和表情符号 |
| `fewer jokes` | menos bromas | moins de blagues | weniger Witze | 冗談を減らす | 少开玩笑 |
| `no exclamation marks` | sin signos de exclamación | sans points d’exclamation | keine Ausrufezeichen | 感嘆符なし | 不用感叹号 |
| `fewer adjectives` | menos adjetivos | moins d’adjectifs | weniger Adjektive | 形容詞を減らす | 少用形容词 |
| `shorter sentences` | frases más cortas | phrases plus courtes | kürzere Sätze | 文を短く | 句子更短 |
| `keep it warm` | que siga siendo cálido | rester chaleureux | herzlich bleiben | 温かみは残す | 保持温度 |
| `no contractions` | sin contracciones | sans formes contractées | keine Kurzformen | 短縮形なし | 不用缩略形式 |
| `standard punctuation` | puntuación estándar | ponctuation standard | übliche Zeichensetzung | 標準的な句読点 | 规范标点 |
| `no fillers` | sin muletillas | sans mots de remplissage | keine Füllwörter | つなぎ言葉なし | 不用口头禅 |
| `complete sentences` | frases completas | phrases complètes | vollständige Sätze | 完全な文で | 完整的句子 |
| `no slang` | sin jerga | sans argot | kein Slang | 俗語なし | 不用俚语 |
| `use contractions` | usar contracciones | formes contractées | Kurzformen verwenden | 短縮形を使う | 使用缩略形式 |
| `everyday words` | palabras cotidianas | mots courants | Alltagswörter | 日常的な言葉 | 日常用语 |
| `speak to “you”` | hablar de “tú” | s’adresser au lecteur | den Leser direkt ansprechen | 読み手に語りかける | 用“你”称呼读者 |
| `a touch of humour` | un toque de humor | une touche d’humour | eine Prise Humor | 少しユーモアを | 带点幽默 |
| `add a thank-you` | añadir un agradecimiento | ajouter un merci | ein Dankeschön ergänzen | お礼を添える | 加一句感谢 |
| `use “you” and “we”` | usar “tú” y “nosotros” | employer « vous » et « nous » | „du“ und „wir“ verwenden | 「あなた」と「私たち」を使う | 使用“你”和“我们” |
| `softer requests` | peticiones más suaves | demandes plus douces | sanftere Bitten | 依頼を柔らかく | 请求更委婉 |
| `acknowledge the reader` | reconocer al lector | tenir compte du lecteur | auf den Leser eingehen | 読み手に配慮する | 照顾读者处境 |
| `no new promises` | sin nuevas promesas | pas de nouvelles promesses | keine neuen Versprechen | 新しい約束はしない | 不加新承诺 |
| `requests, not commands` | peticiones, no órdenes | des demandes, pas des ordres | Bitten statt Befehle | 命令ではなく依頼に | 用请求代替命令 |
| `add thanks` | añadir las gracias | ajouter des remerciements | Dank ergänzen | 感謝を添える | 加上致谢 |
| `please mid-sentence` | «por favor» en mitad de la frase | « s’il vous plaît » en milieu de phrase | „bitte“ mitten im Satz | 「どうか」は文中に | “请”放在句中 |
| `drop “actually”` | quitar “en realidad” | retirer « en fait » | „eigentlich“ streichen | 「実は」を削る | 去掉“其实” |
| `keep the request` | mantener la petición | garder la demande | die Bitte beibehalten | 依頼内容は変えない | 保留请求本身 |
| `add light hedges` | matizar un poco | nuancer légèrement | leicht abschwächen | 少しぼかす | 适当留有余地 |
| `“I” statements` | frases en primera persona | des phrases au « je » | Ich-Botschaften | 「私」を主語に | 用“我”来表述 |
| `suggest, don't demand` | sugerir, no exigir | suggérer, pas exiger | vorschlagen statt fordern | 要求せず提案する | 建议而非要求 |
| `no absolutes` | sin absolutos | pas d’absolus | keine absoluten Aussagen | 断定語なし | 不用绝对化的词 |
| `keep the deadline` | mantener el plazo | garder l’échéance | die Frist beibehalten | 期限は残す | 保留截止时间 |
| `lead with what works` | empezar por lo que funciona | commencer par ce qui marche | mit dem Positiven beginnen | 良い点から始める | 先说做得好的 |
| `criticism as suggestion` | la crítica como sugerencia | la critique en suggestion | Kritik als Vorschlag | 批判を提案の形に | 把批评变成建议 |
| `no blame words` | sin culpar | sans mots accusateurs | keine Schuldzuweisungen | 責める言葉なし | 不用指责的词 |
| `hedge disagreement` | matizar el desacuerdo | nuancer le désaccord | Widerspruch abfedern | 反対意見は控えめに | 委婉表达异议 |
| `keep the facts` | mantener los hechos | garder les faits | Fakten beibehalten | 事実は変えない | 保留事实 |
| `point first` | lo esencial primero | l’essentiel d’abord | das Wichtigste zuerst | 要点を先に | 开门见山 |
| `no hedges` | sin rodeos | sans précautions oratoires | keine Abschwächungen | ぼかし表現なし | 不含糊其辞 |
| `no preamble` | sin preámbulos | sans préambule | keine Einleitung | 前置きなし | 不要铺垫 |
| `a clear ask` | una petición clara | une demande claire | eine klare Bitte | はっきりした依頼 | 明确的请求 |
| `stay polite` | seguir siendo cortés | rester poli | höflich bleiben | 礼儀は保つ | 保持礼貌 |
| `no needless apologies` | sin disculpas innecesarias | pas d’excuses inutiles | keine unnötigen Entschuldigungen | 不要な謝罪なし | 不做多余的道歉 |
| `active voice` | voz activa | voix active | Aktiv statt Passiv | 能動態 | 主动语态 |
| `“will”, not “try to”` | «haré», no «intentaré» | « je vais », pas « j’essaierai » | „werde“ statt „versuche“ | 「〜してみる」より「〜する」 | 用“会”，不用“尽量” |
| `statements, not questions` | afirmaciones, no preguntas | des affirmations, pas des questions | Aussagen statt Fragen | 疑問ではなく断言 | 陈述而非提问 |
| `don't overstate` | no exagerar | ne pas exagérer | nicht übertreiben | 誇張しない | 不夸大 |
| `vary sentence length` | variar la longitud de las frases | varier la longueur des phrases | Satzlänge variieren | 文の長さに変化を | 长短句交替 |
| `verbs, not nouns` | verbos, no sustantivos | des verbes, pas des noms | Verben statt Substantive | 名詞より動詞 | 多用动词，少用名词 |
| `no stock phrases` | sin frases hechas | pas de formules toutes faites | keine Floskeln | 決まり文句なし | 不用套话 |
| `same politeness` | la misma cortesía | même degré de politesse | gleich höflich | 丁寧さは同じ | 礼貌程度不变 |
| `no loaded words` | sin palabras cargadas | sans mots connotés | keine wertenden Wörter | 偏った言葉なし | 不用带倾向的词 |
| `no intensifiers` | sin intensificadores | sans intensifs | keine Verstärker | 強調語なし | 不用程度副词 |
| `attribute claims` | atribuir las afirmaciones | attribuer les affirmations | Aussagen belegen | 出典を示す | 注明观点来源 |
| `both sides` | ambas partes | les deux points de vue | beide Seiten | 両方の立場 | 兼顾双方 |
| `about a third shorter` | un tercio más corto | un tiers plus court | etwa ein Drittel kürzer | 3分の1ほど短く | 缩短约三分之一 |
| `about half` | la mitad, más o menos | environ la moitié | etwa halb so lang | 半分くらいに | 约一半长度 |
| `no repeated points` | sin ideas repetidas | pas de redites | keine Wiederholungen | 繰り返しを省く | 删去重复内容 |
| `no intro or sign-off` | sin introducción ni despedida | ni introduction ni formule finale | ohne Einleitung und Schlussformel | 前置きと結びを省く | 去掉开场白和结束语 |
| `drop examples` | quitar ejemplos | retirer les exemples | Beispiele streichen | 例を省く | 删去例子 |
| `keep every fact` | mantener todos los datos | garder tous les faits | alle Fakten behalten | 事実はすべて残す | 保留所有事实 |
| `no filler words` | sin palabras de relleno | sans mots de remplissage inutiles | keine Füllwörter mehr | 余計な言葉なし | 去掉赘词 |
| `fewer adverbs` | menos adverbios | moins d’adverbes | weniger Adverbien | 副詞を減らす | 少用副词 |
| `no wordy phrases` | sin expresiones largas | sans tournures lourdes | keine umständlichen Wendungen | 冗長な言い回しなし | 不用冗长的说法 |
| `unhide verbs` | verbos en vez de sustantivos | rendre les verbes visibles | Verben statt Nominalstil | 名詞化を動詞に戻す | 把名词化改回动词 |
| `cut words, not ideas` | recortar palabras, no ideas | couper des mots, pas des idées | Wörter kürzen, nicht Ideen | 言葉は削り内容は残す | 删字不删意 |
| `an example per point` | un ejemplo por idea | un exemple par point | ein Beispiel pro Punkt | 要点ごとに例を | 每个要点一个例子 |
| `explain the reasons` | explicar los motivos | expliquer les raisons | Gründe erklären | 理由を説明する | 说明原因 |
| `add transitions` | añadir transiciones | ajouter des transitions | Übergänge ergänzen | つなぎを加える | 增加过渡 |
| `spell out shorthand` | desarrollar abreviaturas | développer les abréviations | Abkürzungen ausschreiben | 略語を書き出す | 写全缩写 |
| `no new facts` | sin datos nuevos | pas de nouveaux faits | keine neuen Fakten | 新しい事実は加えない | 不加新事实 |
| `about a third longer` | un tercio más largo | un tiers plus long | etwa ein Drittel länger | 3分の1ほど長く | 加长约三分之一 |
| `one idea per sentence` | una idea por frase | une idée par phrase | ein Gedanke pro Satz | 1文に1つの考え | 一句一个意思 |
| `under 20 words` | menos de 20 palabras | moins de 20 mots | unter 20 Wörtern | 1文20語以内 | 每句不超过20个词 |
| `say who does what` | decir quién hace qué | dire qui fait quoi | sagen, wer was tut | 誰が何をするか明示 | 说清谁做什么 |
| `define jargon` | definir la jerga | définir le jargon | Fachbegriffe erklären | 専門用語を説明する | 解释术语 |
| `main point first` | la idea principal primero | l’idée principale d’abord | Hauptaussage zuerst | 要点を最初に | 要点放在前面 |
| `keep it accurate` | que siga siendo exacto | rester exact | genau bleiben | 正確さは保つ | 保持准确 |
| `short sentences` | frases cortas | phrases courtes | kurze Sätze | 短い文 | 短句 |
| `explain acronyms` | explicar las siglas | expliquer les sigles | Abkürzungen erklären | 略語を説明する | 解释缩略语 |
| `present tense` | tiempo presente | présent de l’indicatif | Präsens | 現在形 | 使用现在时 |
| `plain words` | palabras sencillas | mots simples | einfache Wörter | 平易な言葉 | 通俗的词 |
| `spell out acronyms` | desarrollar las siglas | écrire les sigles en toutes lettres | Akronyme ausschreiben | 略語を正式名称で | 写出缩略语全称 |
| `explain kept terms` | explicar los términos que quedan | expliquer les termes conservés | verbliebene Begriffe erklären | 残す用語は説明する | 解释保留的术语 |
| `no buzzwords` | sin palabras de moda | sans mots à la mode | keine Modewörter | 流行語なし | 不用流行语 |
| `keep needed terms` | mantener los términos necesarios | garder les termes nécessaires | nötige Begriffe behalten | 必要な用語は残す | 保留必要的术语 |
| `better transitions` | mejores transiciones | de meilleures transitions | bessere Übergänge | つなぎを良くする | 改进过渡 |
| `fix awkward phrasing` | corregir frases torpes | corriger les tournures maladroites | holprige Formulierungen glätten | ぎこちない表現を直す | 修改别扭的表达 |
| `clear pronouns` | pronombres claros | des pronoms clairs | eindeutige Pronomen | 指示語を明確に | 代词指代清楚 |
| `no new content` | sin contenido nuevo | pas de nouveau contenu | keine neuen Inhalte | 内容は加えない | 不加新内容 |
| `replace vague words` | sustituir palabras vagas | remplacer les mots vagues | vage Wörter ersetzen | 曖昧な言葉を置き換える | 替换含糊的词 |
| `use the text's numbers` | usar las cifras del texto | utiliser les chiffres du texte | Zahlen aus dem Text nutzen | 本文の数字を使う | 使用文中的数字 |
| `mark missing details` | marcar los datos que faltan | signaler les détails manquants | fehlende Angaben markieren | 不足情報は印を付ける | 标出缺少的细节 |
| `a concrete example` | un ejemplo concreto | un exemple concret | ein konkretes Beispiel | 具体例を1つ | 一个具体例子 |
| `no filler qualifiers` | sin matices de relleno | sans précisions inutiles | keine leeren Einschränkungen | 無駄な限定語なし | 去掉多余的修饰语 |
| `one topic per paragraph` | un tema por párrafo | un sujet par paragraphe | ein Thema pro Absatz | 1段落に1テーマ | 一段一个主题 |
| `logical order` | orden lógico | ordre logique | logische Reihenfolge | 論理的な順序 | 逻辑顺序 |
| `topic sentence first` | la frase principal primero | la phrase clé d’abord | Kernsatz zuerst | 主題文を先頭に | 主题句放在段首 |
| `signpost the steps` | señalar los pasos | baliser les étapes | Schritte kennzeichnen | 手順を示す言葉を | 标明步骤 |
| `strong verbs` | verbos fuertes | des verbes forts | starke Verben | 力のある動詞 | 有力的动词 |
| `cut the warm-up` | quitar el calentamiento | couper l’entrée en matière | Anlauf streichen | 前置きを削る | 删掉热身句 |
| `end strong` | terminar con fuerza | finir en force | stark enden | 力強く締める | 结尾有力 |
| `no hype words` | sin palabras exageradas | sans mots tape-à-l’œil | keine Reklamewörter | 大げさな言葉なし | 不用夸张的词 |
| `a strong opening` | un comienzo potente | une ouverture forte | ein starker Einstieg | 印象的な書き出し | 有力的开头 |
| `concrete images` | imágenes concretas | des images concrètes | konkrete Bilder | 具体的なイメージ | 具体的形象 |
| `upbeat words` | palabras positivas | des mots positifs | positive Wörter | 前向きな言葉 | 积极的用词 |
| `one exclamation mark` | un signo de exclamación | un point d’exclamation | ein Ausrufezeichen | 感嘆符を1つ | 一个感叹号 |
| `lead with the positive` | empezar por lo positivo | commencer par le positif | mit dem Positiven einsteigen | 良いことから始める | 先说好消息 |
| `emoji allowed` | emoji permitido | emoji autorisé | Emoji erlaubt | 絵文字OK | 可以用表情符号 |
| `don't exaggerate` | sin exagerar | sans exagérer | nichts übertreiben | 大げさにしない | 不要夸张 |
| `benefit first` | el beneficio primero | le bénéfice d’abord | Nutzen zuerst | 利点を先に | 先讲好处 |
| `a call to action` | una llamada a la acción | un appel à l’action | eine Handlungsaufforderung | 行動を促す一文 | 号召行动 |
| `back the claims` | respaldar las afirmaciones | étayer les affirmations | Aussagen begründen | 主張に根拠を | 论点有依据 |
| `answer the objection` | responder a la objeción | répondre à l’objection | den Einwand entkräften | 反論に答える | 回应反对意见 |
| `no invented claims` | sin datos inventados | rien d’inventé | nichts erfinden | 作り話はしない | 不编造论据 |
| `sensory detail` | detalles sensoriales | des détails sensoriels | sinnliche Details | 五感に訴える描写 | 感官细节 |
| `one comparison` | una comparación | une comparaison | ein Vergleich | 比喩を1つ | 一个比喻 |
| `replace clichés` | sustituir clichés | remplacer les clichés | Klischees ersetzen | 決まり文句を置き換える | 替换陈词滥调 |
| `vary the rhythm` | variar el ritmo | varier le rythme | Rhythmus variieren | リズムに変化を | 变换节奏 |
| `one light joke` | una broma ligera | une petite blague | ein kleiner Witz | 軽い冗談を1つ | 一个轻松的笑话 |
| `casual words` | palabras informales | des mots familiers | lockere Wörter | くだけた言葉 | 口语化的词 |
| `wordplay allowed` | juegos de palabras permitidos | jeux de mots autorisés | Wortspiele erlaubt | 言葉遊びOK | 可以用文字游戏 |
| `keep the information` | mantener la información | garder l’information | alle Informationen behalten | 情報はすべて残す | 保留所有信息 |
| `grammar and spelling only` | solo gramática y ortografía | grammaire et orthographe seulement | nur Grammatik und Rechtschreibung | 文法と綴りのみ | 只改语法和拼写 |
| `better word choice` | mejores palabras | un meilleur choix de mots | bessere Wortwahl | 言葉選びを良く | 用词更好 |
| `tighter` | más ajustado | plus resserré | straffer | 引き締める | 更紧凑 |
| `smoother flow` | más fluidez | plus de fluidité | flüssiger | 流れをなめらかに | 更流畅 |
| `keep my voice` | mantener mi voz | garder mon style | meinen Stil behalten | 自分らしさは残す | 保留我的风格 |
| `same length` | misma longitud | même longueur | gleiche Länge | 長さは同じ | 长度不变 |
| `fix grammar` | corregir la gramática | corriger la grammaire | Grammatik korrigieren | 文法を直す | 修正语法 |
| `consistent style` | estilo coherente | style cohérent | einheitlicher Stil | 表記を統一 | 格式统一 |
| `no repetition` | sin repeticiones | pas de répétitions | keine Wortwiederholungen | 重複をなくす | 去掉重复 |
| `keep the wording` | mantener la redacción | garder la formulation | Wortlaut beibehalten | 言い回しは残す | 保留原有措辞 |
| `careful claims` | afirmaciones prudentes | des affirmations prudentes | vorsichtige Aussagen | 主張は慎重に | 表述审慎 |
| `precise terms` | términos precisos | des termes précis | präzise Begriffe | 正確な用語 | 精确的术语 |
| `third person` | tercera persona | troisième personne | dritte Person | 三人称 | 第三人称 |
| `no exclamations` | sin exclamaciones | sans exclamations | keine Ausrufe | 感嘆表現なし | 不用感叹 |
| `keep the data` | mantener los datos | garder les données | Daten beibehalten | データは変えない | 保留数据 |
| `no stock AI phrases` | sin frases típicas de IA | sans tics de langage d’IA | keine typischen KI-Floskeln | AIらしい決まり文句なし | 去掉 AI 套话 |
| `no dash chains` | sin cadenas de guiones | sans enchaînements de tirets | keine Gedankenstrich-Ketten | ダッシュの連続なし | 不用连串破折号 |
| `no summary ending` | sin resumen final | sans résumé final | keine Zusammenfassung am Schluss | まとめの締めなし | 不用总结式结尾 |
| `keep the meaning` | mantener el sentido | garder le sens | Sinn beibehalten | 意味は変えない | 保留原意 |
| `explain every term` | explicar cada término | expliquer chaque terme | jeden Begriff erklären | 用語はすべて説明 | 解释每个术语 |
| `one step at a time` | paso a paso | étape par étape | Schritt für Schritt | 一歩ずつ | 循序渐进 |
| `an everyday example` | un ejemplo cotidiano | un exemple du quotidien | ein Alltagsbeispiel | 身近な例を1つ | 一个日常例子 |
| `no assumed knowledge` | sin dar nada por sabido | sans connaissances préalables | kein Vorwissen voraussetzen | 予備知識を前提にしない | 不预设背景知识 |
| `skip the basics` | omitir lo básico | passer les bases | Grundlagen überspringen | 基本は省く | 略过基础知识 |
| `denser` | más denso | plus dense | dichter | 密度を高く | 更精炼 |
| `numbers first` | las cifras primero | les chiffres d’abord | Zahlen zuerst | 数字を先に | 数据放在前面 |
| `summary first` | el resumen primero | le résumé d’abord | Zusammenfassung zuerst | 要約を先に | 先给摘要 |
| `the decision needed` | la decisión necesaria | la décision attendue | die nötige Entscheidung | 必要な判断を明示 | 需要的决定 |
| `cost and timing` | coste y plazos | coût et calendrier | Kosten und Zeitplan | 費用と時期 | 成本和时间 |
| `risks` | riesgos | risques | Risiken | リスク | 风险 |
| `shorter` | más corto | plus court | kürzer | 短く | 更短 |

### The forms

English keeps its own list (in `AIPromptLexicon.definitions`). All six lists are matched
whatever the interface language.

#### German (`de`)

| Word | Forms |
|---|---|
| professional | professionell, professioneller, seriös, seriöser, geschäftsmäßig, geschäftsmäßiger, weniger salopp |
| formal | formell, formeller, förmlich, förmlicher, siezen, sie-form, in der sie-form |
| casual | lockerer, ungezwungen, ungezwungener, umgangssprachlich, umgangssprachlicher, informell, informeller, lässig, lässiger, weniger förmlich, weniger formell, duzen, du-form, in der du-form |
| friendly | freundlich, freundlicher, herzlich, herzlicher, wärmer, netter, nahbar, nahbarer, sympathisch, sympathischer |
| polite | höflich, höflicher, respektvoll, respektvoller, zuvorkommend, zuvorkommender |
| softer | sanfter, weicher, milder, abmildern, abschwächen, entschärfen, weniger hart, weniger schroff, weniger aggressiv, behutsamer |
| diplomatic | diplomatisch, diplomatischer, taktvoll, taktvoller, feinfühlig, feinfühliger |
| direct | direkter, geradliniger, auf den punkt, ohne umschweife, unverblümt, unverblümter |
| confident | selbstbewusst, selbstbewusster, selbstsicher, selbstsicherer, entschiedener, souveräner, weniger zögerlich |
| natural | natürlicher, weniger steif, weniger hölzern, weniger roboterhaft, menschlicher |
| neutral | neutraler, sachlich, sachlicher, objektiv, objektiver, unvoreingenommen, ausgewogen, ausgewogener |
| shorter | kürzer, kürzen, kürze, verkürzen, verkürze, gekürzt, weniger lang, eindampfen |
| concise | prägnant, prägnanter, knapper, straffen, straffer, kompakter, bündig, bündiger, weniger wortreich, weniger geschwätzig |
| longer | länger, verlängern, verlängere, ausführlich, ausführlicher, ausbauen, erweitern, erweitere, detaillierter, mehr details, vertiefen |
| clearer | klarer, deutlicher, verständlich, verständlicher, lesbarer, eindeutiger, verdeutlichen, verdeutliche, leichter zu folgen |
| simpler | einfacher, vereinfachen, vereinfache, vereinfacht, schlichter, einfache sprache, leichte sprache, in einfachen worten |
| jargon | fachjargon, weniger jargon, weniger fachjargon, fachsprache, weniger fachsprache, fachbegriffe, weniger fachbegriffe, weniger technisch, weniger buzzwords, schlagwörter |
| flow | flüssig, flüssiger, fließender, runder, abrunden, glätten, geschmeidiger, kohärenter, zusammenhängender, lesefluss |
| specific | konkreter, genauer, präziser, präzise, spezifischer, weniger vage, weniger schwammig, weniger allgemein |
| structured | strukturiert, strukturierter, gegliedert, besser gegliedert, geordneter, übersichtlicher, logischer, besser organisiert |
| punchier | knackig, knackiger, schlagkräftiger, wirkungsvoller, eindringlicher, pointierter, zackiger, mit mehr biss, mehr wumms |
| engaging | fesselnd, fesselnder, packend, packender, spannend, spannender, interessanter, ansprechender, weniger langweilig, langweilig |
| enthusiastic | begeistert, begeisterter, enthusiastisch, enthusiastischer, schwungvoll, schwungvoller, lebhafter, lebendiger, motivierter, optimistischer, positiver |
| persuasive | überzeugend, überzeugender, verkaufsstärker, werblicher, mitreißender |
| creative | kreativ, kreativer, fantasievoll, fantasievoller, phantasievoller, bildhaft, bildhafter, anschaulich, anschaulicher, origineller |
| playful | verspielt, verspielter, lustig, lustiger, witzig, witziger, humorvoll, humorvoller, unterhaltsam, unterhaltsamer, mit humor, augenzwinkernd |
| better | besser, verbessern, verbessere, verbessert, überarbeiten, überarbeite, aufpolieren, polieren, optimieren, optimiere, schöner, schöner formulieren |
| cleaner | sauber, sauberer, säubern, aufräumen, aufgeräumter, ordentlicher, bereinigen, bereinige |
| academic | akademisch, akademischer, wissenschaftlich, wissenschaftlicher, für eine arbeit, für eine hausarbeit, für ein paper |
| humanize | humanisieren, menschlich klingen, menschlicher klingen, weniger nach ki, nicht nach ki, weniger ki, wie ein mensch |
| beginners | anfänger, für anfänger, einsteiger, für einsteiger, laien, für laien, ohne vorwissen, allgemeinverständlich, für alle verständlich |
| experts | experten, für experten, fachleute, für fachleute, fachpublikum, spezialisten, technischer, für ingenieure |
| executives | führungskräfte, für führungskräfte, geschäftsführung, vorstand, meinen chef, meine chefin, für meinen chef, vorgesetzte, vorgesetzten, entscheider, stakeholder |

#### French (`fr`)

| Word | Forms |
|---|---|
| professional | professionnel, professionnelle, plus professionnel, plus professionnelle, professionnellement, moins familier |
| formal | formel, formelle, plus formel, plus formelle, soutenu, plus soutenu, vouvoyer, vouvoiement |
| casual | décontracté, plus décontracté, détendu, plus détendu, plus familier, informel, plus informel, moins formel, moins formelle, tutoyer, tutoiement, conversationnel |
| friendly | amical, plus amical, chaleureux, plus chaleureux, chaleureuse, aimable, plus aimable, sympathique, sympa, plus sympa, cordial, plus cordial |
| polite | plus poli, plus polie, poliment, courtois, plus courtois, respectueux, plus respectueux |
| softer | plus doux, plus douce, adoucir, adoucis, adoucissez, atténuer, moins dur, moins brutal, moins sec, moins agressif, plus délicat |
| diplomatic | diplomate, plus diplomate, diplomatique, avec tact, avec plus de tact |
| direct | plus direct, plus directe, droit au but, sans détour, sans détours, plus franc |
| confident | confiant, plus confiant, plus assuré, affirmé, plus affirmé, assertif, plus assertif, moins hésitant, avec assurance |
| natural | naturel, plus naturel, naturelle, plus naturelle, moins rigide, moins guindé, moins robotique, plus humain |
| neutral | neutre, plus neutre, objectif, plus objectif, impartiale, factuel, plus factuel |
| shorter | plus court, plus courte, raccourcir, raccourcis-le, raccourcissez, écourter, réduire, réduis, moins long, moins longue, condenser |
| concise | concis, plus concis, plus concise, plus succinct, plus bref, plus brève, resserrer, resserre, moins verbeux, moins bavard |
| longer | plus long, plus longue, allonger, allonge, rallonger, développer, développe, développez, étoffer, plus détaillé, plus détaillée, plus de détails, approfondir |
| clearer | clair, plus clair, plus claire, clarifier, clarifie, clarifiez, lisible, plus lisible, compréhensible, plus compréhensible, moins confus, plus limpide |
| simpler | plus simple, simplifier, simplifie, simplifiez, en termes simples, plus facile à lire, langage simple |
| jargon | moins de jargon, jargonneux, moins technique, termes techniques, moins de termes techniques, mots à la mode |
| flow | fluide, plus fluide, fluidité, fluidifier, mieux enchaîné, enchaînements, plus cohérent, cohérent, se lit mieux, plus coulant |
| specific | précis, plus précis, plus précise, spécifique, plus spécifique, concret, plus concret, concrète, plus concrète, moins vague, moins flou |
| structured | plus structuré, mieux structuré, bien structuré, structurer, restructurer, mieux organisé, plus organisé, plus logique |
| punchier | percutant, plus percutant, percutante, plus percutante, plus d’impact, plus d'impact, incisif, plus incisif, plus mordant, plus punchy |
| engaging | captivant, plus captivant, engageant, plus engageant, intéressant, plus intéressant, accrocheur, plus accrocheur, moins ennuyeux, ennuyeux |
| enthusiastic | enthousiaste, plus enthousiaste, plus dynamique, énergique, plus énergique, entraînant, plus vivant, plus positif |
| persuasive | persuasif, plus persuasif, convaincant, plus convaincant, convaincante, vendeur, plus vendeur |
| creative | créatif, plus créatif, créative, imaginatif, plus imaginatif, plus imagé, coloré, plus coloré, plus descriptif, évocateur, plus évocateur, plus original |
| playful | ludique, plus ludique, drôle, plus drôle, amusant, plus amusant, humoristique, avec humour, plein d’humour, plein d'humour, espiègle, plus léger, plus légère, plus fun |
| better | mieux, en mieux, améliorer, améliore, améliorez, peaufiner, peaufine, polir, retravailler, retravaille |
| cleaner | plus propre, nettoyer, nettoie, nettoyez, mettre au propre, mets au propre, épurer, épure, plus net, plus nette, plus soigné |
| academic | académique, plus académique, universitaire, scientifique, plus scientifique, style académique, pour un article, pour un mémoire |
| humanize | humaniser, moins ia, moins artificiel, comme un humain, pas comme une ia, moins comme une ia, sonner humain |
| beginners | débutants, pour débutants, pour les débutants, novices, néophytes, non-spécialistes, grand public, pour le grand public, non-initiés |
| experts | pour experts, pour des experts, spécialistes, plus technique, pour ingénieurs, pour des ingénieurs, public averti |
| executives | dirigeants, pour la direction, à la direction, cadres, mon patron, ma patronne, mon chef, ma cheffe, mon manager, comité de direction, décideurs, parties prenantes |

#### Spanish (`es`)

| Word | Forms |
|---|---|
| professional | profesional, más profesional, profesionalmente, más serio, más seria, menos coloquial |
| formal | más formal, formalmente, de usted, tratar de usted |
| casual | más informal, más casual, relajado, más relajado, desenfadado, más desenfadado, coloquial, más coloquial, menos formal, tutear, tutea |
| friendly | amable, más amable, amigable, más amigable, cálido, más cálido, cercano, más cercano, más cordial, simpático, más simpático |
| polite | más cortés, cortésmente, educado, más educado, respetuoso, más respetuoso, con cortesía |
| softer | más suave, suavizar, suaviza, suavízalo, suavízala, menos duro, menos brusco, menos agresivo, más delicado |
| diplomatic | diplomático, más diplomático, diplomática, con tacto, con más tacto |
| direct | directo, más directo, directa, al grano, ir al grano, ve al grano, sin rodeos, más franco |
| confident | más seguro, más segura, con seguridad, con más seguridad, con confianza, más confiado, más firme, asertivo, más asertivo, seguro de sí, menos dubitativo |
| natural | más natural, con naturalidad, menos rígido, menos robótico, menos acartonado, más humano |
| neutral | más neutral, neutro, más neutro, más objetivo, imparcial, más imparcial, sin sesgo, menos sesgado |
| shorter | más corto, más corta, acortar, acorta, acórtalo, acórtala, recortar, recorta, recórtalo, reducir, redúcelo, menos largo, condensar, condénsalo |
| concise | conciso, más conciso, concisa, sucinto, más sucinto, breve, más breve, menos verboso, sin relleno, sin paja |
| longer | más largo, más larga, alargar, alarga, alárgalo, ampliar, amplíalo, desarrollar, desarrolla, desarróllalo, más detallado, más detalle, más detalles, profundizar, extender |
| clearer | más claro, más clara, aclarar, aclara, acláralo, clarificar, legible, más legible, comprensible, más comprensible, entendible, más entendible, menos confuso |
| simpler | más simple, sencillo, más sencillo, simplificar, simplifica, simplifícalo, más fácil, fácil de leer, lenguaje sencillo, en palabras sencillas |
| jargon | jerga, menos jerga, tecnicismos, menos tecnicismos, menos técnico, términos técnicos, palabras de moda |
| flow | fluido, más fluido, fluidez, con más fluidez, coherente, más coherente, que fluya, fluya mejor, se lea mejor |
| specific | específico, más específico, más preciso, más concreto, concreto, concreta, menos vago, menos ambiguo |
| structured | estructurado, más estructurado, mejor estructurado, organizado, más organizado, mejor organizado, más lógico, más ordenado |
| punchier | contundente, más contundente, impactante, más impactante, con más fuerza, con gancho, más gancho, incisivo, más incisivo |
| engaging | atractivo, más atractivo, interesante, más interesante, cautivador, más cautivador, atrapante, ameno, más ameno, menos aburrido, aburrido |
| enthusiastic | entusiasta, más entusiasta, entusiasmado, animado, más animado, enérgico, más enérgico, más dinámico, vivaz, más positivo, con más energía |
| persuasive | persuasivo, más persuasivo, persuasiva, convincente, más convincente, más vendedor |
| creative | creativo, más creativo, creativa, imaginativo, más imaginativo, más vívido, colorido, más colorido, descriptivo, más descriptivo, más original, evocador |
| playful | divertido, más divertido, divertida, gracioso, más gracioso, con humor, humorístico, juguetón, más juguetón, ingenioso, más ingenioso, más ligero |
| better | mejor, mejorar, mejora, mejóralo, mejórala, pulir, púlelo, perfeccionar, refinar, refina, retocar, retoca, mejor redactado |
| cleaner | más limpio, limpiar, limpia, límpialo, pulcro, más pulcro, depurar, depura, más prolijo, prolijo |
| academic | académico, más académico, académica, científico, más científico, estilo académico, para un artículo, para una tesis |
| humanize | humanizar, humaniza, humanízalo, menos ia, menos artificial, que suene humano, que no suene a ia, sin sonar a ia |
| beginners | principiantes, para principiantes, novatos, no expertos, público general, para todos los públicos, no técnicos, sin conocimientos previos |
| experts | expertos, para expertos, especialistas, más técnico, para ingenieros, público experto |
| executives | directivos, ejecutivos, para la dirección, alta dirección, mi jefe, mi jefa, gerencia, junta directiva, partes interesadas |

#### Japanese (`ja`)

| Word | Forms |
|---|---|
| professional | プロフェッショナル, プロらしく, プロっぽく, ビジネスライク, ビジネス向け, ビジネスらしく, 仕事向け |
| formal | フォーマル, 硬めに, 堅めに, 改まった, かしこまった, 敬語 |
| casual | カジュアル, くだけた, 砕けた, 気軽な, 軽い感じ, タメ口, 話し言葉, 口語 |
| friendly | 親しみやすく, 親しみやすい, 親しみのある, フレンドリー, 温かみ, 温かい, 温かく, あたたかい, あたたかく |
| polite | 丁寧な言い方, 丁寧な表現, 丁寧な口調, もっと丁寧, 丁寧にして, 丁寧に書, 礼儀正しく, 失礼のない |
| softer | 柔らかく, やわらかく, 柔らかい, やわらかい, 優しく, やさしく, 穏やか, きつくない, とげのない, トゲのない |
| diplomatic | 角が立たない, 角を立てず, 外交的, 波風を立てない, 配慮した, 配慮のある |
| direct | 単刀直入, 端的に, ストレートに, はっきりと, 率直に, 率直な, 結論から, 要点から |
| confident | 自信を持って, 自信のある, 自信がある, 自信満々, 堂々と, 言い切る, 言い切って, 断定的 |
| natural | 自然に, 自然な, もっと自然, 不自然, ナチュラル, 硬さを取って, ロボットっぽくない, 機械的でない |
| neutral | 中立的, 中立, 客観的, 客観, 公平, 偏りのない, 偏りなく |
| shorter | 短く, もっと短く, 短めに, 短縮, 縮めて, 削って, 手短に, 文字数を減らして |
| concise | 簡潔, 簡潔に, もっと簡潔, 冗長, くどくない, くどさ, 無駄を省いて, 無駄を削って, 要点だけ |
| longer | 長くして, もっと長く, 長めに, 膨らませて, 詳しく, もっと詳しく, 詳細に, 肉付け, 加筆, 補足して |
| clearer | 分かりやすく, わかりやすく, 分かりやすい, わかりやすい, 明確に, 明確, 明快, 明瞭, 読みやすく, 読みやすい |
| simpler | 簡単に, 簡単な, もっと簡単, シンプルに, シンプル, 平易, 易しく, 噛み砕いて, かみ砕いて, やさしい言葉 |
| jargon | 専門用語, 業界用語, ジャーゴン, カタカナ語, 横文字, 難しい言葉, 専門的すぎ |
| flow | 流れ, 流れを良く, 流れよく, 流れるように, 自然な流れ, つながり, スムーズに, スムーズ, なめらかに, 滑らかに |
| specific | 具体的, 具体的に, もっと具体的, 具体性, 曖昧, あいまい, 曖昧さ, 正確に |
| structured | 構成を整えて, 構成を見直して, 構造化, 整理して, 整理された, 論理的に, 論理的な, 体系的 |
| punchier | インパクト, インパクトのある, パンチのある, パンチの効いた, キレのある, 力強く, 力強い, メリハリ, 歯切れよく, 歯切れの良い |
| engaging | 魅力的, 面白く, おもしろく, 興味を引く, 引き込まれる, 惹きつける, 引きつける, 退屈, 飽きない, 読ませる |
| enthusiastic | 熱意, 熱意を込めて, 情熱的, 元気よく, 元気な感じ, ポジティブ, 前向き, 前向きに, 明るく, 明るい, 活気, 生き生き, いきいき |
| persuasive | 説得力, 説得力のある, 説得的, 納得感, 納得できる, 訴求力 |
| creative | 創造的, クリエイティブ, 想像力, 想像力豊か, 独創的, 鮮やか, 表現豊か, 描写豊か, 比喩 |
| playful | 遊び心, 楽しく, 楽しい, ユーモア, ユーモアのある, 面白おかしく, 軽やか, 軽快, おちゃめ, ウィット |
| better | より良く, もっと良く, 良くして, 改善, 改良, 推敲, 磨いて, ブラッシュアップ, 手直し, 洗練 |
| cleaner | きれいに, 綺麗に, 整えて, 体裁を整えて, 誤字脱字, すっきり, スッキリ |
| academic | 学術的, 学術的に, アカデミック, 学問的, 論文調, 論文向け, 論文風, 論文らしく |
| humanize | 人間らしく, 人間味, 人間っぽく, aiっぽくない, aiっぽさ, aiらしさ, ai臭さ |
| beginners | 初心者, 初心者向け, 素人, 一般向け, 一般の人, 入門, 予備知識なし |
| experts | 専門家, 専門家向け, 上級者, 上級者向け, エンジニア向け, 技術者向け, 専門的に, もっと専門的 |
| executives | 経営陣, 経営層, 役員, 上司, 管理職, 幹部, 意思決定者, ステークホルダー, マネージャー |

#### Simplified Chinese (`zh-Hans`)

| Word | Forms |
|---|---|
| professional | 更专业, 专业一点, 专业些, 专业化, 显得专业, 商务风格, 商务化 |
| formal | 正式, 更正式, 正式一点, 正式些, 书面语, 更书面 |
| casual | 非正式, 随意一点, 随意些, 随性, 口语, 口语化, 轻松, 轻松一点, 轻松些 |
| friendly | 友好, 更友好, 友善, 更友善, 亲切, 更亲切, 热情, 更热情, 更温暖, 温暖一点, 平易近人 |
| polite | 礼貌, 更礼貌, 礼貌一点, 客气, 客气一点, 更客气 |
| softer | 柔和, 更柔和, 温和, 更温和, 缓和, 软一点, 不那么强硬, 不那么尖锐 |
| diplomatic | 委婉, 更委婉, 得体, 更得体, 圆滑, 更圆滑, 有分寸 |
| direct | 更直接, 直接一点, 直接些, 直截了当, 开门见山, 直奔主题, 直白, 更直白 |
| confident | 自信, 更自信, 自信一点, 果断, 更果断, 坚定, 更坚定, 有底气, 语气肯定 |
| natural | 更自然, 自然一点, 自然些, 读起来自然, 不生硬, 生硬, 更地道, 地道一点 |
| neutral | 更中立, 客观, 更客观, 客观一点, 公正, 不偏不倚, 不带偏见 |
| shorter | 更短, 短一点, 短一些, 短些, 缩短, 删减, 压缩, 简短一点, 减少篇幅 |
| concise | 简洁, 更简洁, 精简, 简练, 精炼, 言简意赅, 简明扼要, 不啰嗦, 别啰嗦, 啰嗦 |
| longer | 更长, 长一点, 长一些, 长些, 加长, 扩写, 扩展, 扩充, 展开, 详细, 更详细, 详细一点, 充实 |
| clearer | 更清楚, 清楚一点, 清楚些, 说清楚, 写清楚, 清晰, 更清晰, 明确, 更明确, 易懂, 好懂, 更易懂, 更好懂, 易读, 更好读 |
| simpler | 更简单, 简单一点, 简单些, 简单点, 简化, 通俗, 通俗易懂, 浅显, 浅显易懂, 白话, 大白话 |
| jargon | 术语, 专业术语, 行话, 黑话, 少用术语, 太专业, 不那么专业, 流行语 |
| flow | 流畅, 更流畅, 通顺, 更通顺, 连贯, 更连贯, 顺畅, 衔接, 过渡, 读起来顺, 行文流畅 |
| specific | 更具体, 具体一点, 具体些, 具体化, 精确, 更精确, 更准确, 准确一点, 笼统, 含糊, 模糊 |
| structured | 有条理, 更有条理, 条理清晰, 结构化, 结构清晰, 调整结构, 有逻辑, 更有逻辑, 逻辑清晰, 层次分明 |
| punchier | 更有力, 有力度, 有力一点, 冲击力, 更有冲击力, 掷地有声, 铿锵有力, 干脆利落, 有张力 |
| engaging | 吸引人, 更吸引人, 引人入胜, 有趣, 更有趣, 抓人, 更抓人, 不无聊, 无聊, 枯燥, 不枯燥 |
| enthusiastic | 热情洋溢, 积极, 更积极, 有活力, 充满活力, 活力, 激情, 兴奋, 振奋, 乐观, 更乐观 |
| persuasive | 说服力, 有说服力, 更有说服力, 打动人, 更打动人, 令人信服 |
| creative | 创意, 有创意, 更有创意, 创造性, 想象力, 富有想象力, 生动, 更生动, 形象生动, 更形象, 画面感, 文学性 |
| playful | 俏皮, 更俏皮, 幽默, 更幽默, 风趣, 诙谐, 好玩, 轻松幽默, 活泼, 更活泼, 逗趣, 搞笑 |
| better | 更好, 好一点, 改进, 改善, 优化, 润色, 打磨, 完善, 修饰, 提升 |
| cleaner | 整洁, 更整洁, 干净, 更干净, 清理, 整理一下, 规整, 错别字 |
| academic | 学术, 更学术, 学术化, 学术性, 学术风格, 论文, 论文风格, 严谨, 更严谨 |
| humanize | 人性化, 更人性化, 像人写的, 不像ai, 别像ai, ai味, 去ai味, ai感, 人味, 有人味 |
| beginners | 初学者, 新手, 入门, 外行, 门外汉, 小白, 零基础, 大众读者, 普通读者, 非专业人士 |
| experts | 专家, 专业人士, 业内人士, 内行, 工程师, 技术人员 |
| executives | 领导, 老板, 高管, 管理层, 上司, 决策者, 董事会, 利益相关者 |

Blockers (claim the span, underline nothing): 流れ星, 得体の知れ, 正式版, 正式发布, 正式上线, 扩展名.
