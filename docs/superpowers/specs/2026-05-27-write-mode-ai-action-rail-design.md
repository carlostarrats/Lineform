# Write Mode AI Action Rail Design

Lineform will replace the automatic selected-text intelligence context menu with an explicit Write-mode AI surface. The toolbar gets an `Intelligence` toggle before `Markdown Basics`. The toggle uses native button-toggle behavior so it has normal, hover, and pressed states.

The toggle state persists across mode changes. In `Write`, an enabled toggle shows a floating vertical action rail over the left side of the editor. In `Read` and `Preview`, the toggle is hidden and the rail is visually gone, but the on/off state is not reset; returning to `Write` restores the rail when the toggle is still on.

The rail contains four selected-text actions in this order: `Clean Markdown`, `Proofread`, `Rewrite`, and `Make Shorter`. Buttons are disabled unless Apple Intelligence is available, no request is currently running, and the current selection contains non-whitespace text. Selecting an action uses the existing `EditorContainerView.runIntelligentEditingAction` flow, preserving the current suggestion review panel, validation, stale-selection checks, and status-bar messaging.

The automatic mouse-selection intelligence menu is removed. Right-click remains focused on normal editing and Markdown formatting. Menu bar intelligence commands and keyboard shortcuts stay available because they are explicit commands, not surprise UI.
